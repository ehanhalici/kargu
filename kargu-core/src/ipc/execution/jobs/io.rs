//! Bounded read retries and stdin acknowledgements; never await child IO here.

use super::{JobOwner, Jobs};
use crate::{
    application::host::Host,
    constants::{limits, timeouts},
    domain::{ByteLimit, ByteOffset, JobId},
    error::CoreError,
    ipc::protocol::{self, RpcId},
    process::{InputChunk, OutputStream, ProcessSupervisor},
};
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio::{sync::oneshot, time::Instant};

enum Action {
    Read {
        stream: OutputStream,
        cursor: ByteOffset,
        limit: ByteLimit,
    },
    Input(oneshot::Receiver<Result<(), CoreError>>),
}
struct Request {
    owner: JobOwner,
    job_id: JobId,
    deadline: Instant,
    action: Action,
    cancelled: bool,
}
#[derive(Default)]
pub(super) struct Requests {
    entries: HashMap<RpcId, Request>,
}
impl Requests {
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.entries
            .values()
            .any(|request| &request.owner.scope.application_id == id)
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.entries.contains_key(id)
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
    pub fn cancel(&mut self, id: &RpcId) {
        if let Some(request) = self.entries.get_mut(id) {
            request.cancelled = true;
        }
    }
    pub fn read(
        &mut self,
        id: RpcId,
        owner: JobOwner,
        job_id: JobId,
        stream: OutputStream,
        cursor: ByteOffset,
        limit: ByteLimit,
    ) -> Result<(), CoreError> {
        self.insert(
            id,
            owner,
            job_id,
            Action::Read {
                stream,
                cursor,
                limit,
            },
        )
    }
    pub fn input(
        &mut self,
        id: RpcId,
        owner: JobOwner,
        job_id: JobId,
        input: Option<InputChunk>,
        jobs: &Jobs,
        supervisor: &ProcessSupervisor,
    ) -> Result<(), CoreError> {
        self.capacity(&id)?;
        let run = &jobs.owned(&owner, &job_id)?.run;
        let ack = supervisor.queue_input(run, &job_id, input)?;
        self.insert(id, owner, job_id, Action::Input(ack))
    }
    fn capacity(&self, id: &RpcId) -> Result<(), CoreError> {
        if self.contains(id) || self.entries.len() >= limits::MAX_PENDING {
            return Err(CoreError::Limit);
        }
        Ok(())
    }
    fn insert(
        &mut self,
        id: RpcId,
        owner: JobOwner,
        job_id: JobId,
        action: Action,
    ) -> Result<(), CoreError> {
        self.capacity(&id)?;
        let deadline = Instant::now()
            .checked_add(timeouts::INPUT_ACK)
            .ok_or(CoreError::ArithmeticOverflow)?;
        self.entries.insert(
            id,
            Request {
                owner,
                job_id,
                action,
                deadline,
                cancelled: false,
            },
        );
        Ok(())
    }
    pub fn tick(&mut self, host: &Host, jobs: &Jobs, supervisor: &ProcessSupervisor) -> Vec<Value> {
        let mut messages = Vec::new();
        self.entries.retain(|id, request| {
            let result = if request.cancelled {
                Some(Err(match request.action {
                    Action::Input(_) => CoreError::InputOutcomeUnknown,
                    Action::Read { .. } => CoreError::Cancelled,
                }))
            } else if Instant::now() >= request.deadline {
                Some(Err(match request.action {
                    Action::Input(_) => CoreError::InputOutcomeUnknown,
                    Action::Read { .. } => CoreError::Deadline,
                }))
            } else if !host.owns_read_scope(&request.owner.scope) {
                Some(Err(CoreError::StaleOwner))
            } else {
                poll(request, jobs, supervisor)
            };
            if let Some(result) = result {
                messages.push(match result {
                    Ok(value) => protocol::success(id, value),
                    Err(error) => super::super::fault(error).response(Some(id)),
                });
                false
            } else {
                true
            }
        });
        messages
    }
}

fn poll(
    request: &mut Request,
    jobs: &Jobs,
    supervisor: &ProcessSupervisor,
) -> Option<Result<Value, CoreError>> {
    let job = match jobs.owned(&request.owner, &request.job_id) {
        Ok(job) => job,
        Err(error) => return Some(Err(error)),
    };
    match &mut request.action {
        Action::Read {
            stream,
            cursor,
            limit,
        } => match supervisor.try_read(&job.run, &request.job_id, *stream, *cursor, *limit) {
            Ok(Some(page)) => Some(Ok(
                json!({"data":page.bytes,"start_cursor":page.start_cursor,
                "next_cursor":page.next_cursor,"truncated":page.truncated,"eof":page.eof}),
            )),
            Ok(None) => None,
            Err(error) => Some(Err(error)),
        },
        Action::Input(ack) => match ack.try_recv() {
            Ok(result) => Some(result.map(|()| json!({"accepted":true}))),
            Err(oneshot::error::TryRecvError::Empty) => None,
            Err(oneshot::error::TryRecvError::Closed) => Some(Err(CoreError::Cancelled)),
        },
    }
}
