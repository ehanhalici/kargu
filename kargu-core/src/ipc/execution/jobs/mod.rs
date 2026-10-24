//! Parent-session/project owned process jobs, independent of RPC waiter lifetime.

mod io;
use crate::{
    application::{
        RunHandle,
        host::{Host, ReadScope},
    },
    constants::{limits, protocol::methods},
    domain::{ApplicationId, ByteLimit, ByteOffset, JobId},
    error::CoreError,
    ipc::protocol::{Fault, RpcId},
    process::{InputChunk, JobStatus, OutputStream, ProcessResult, ProcessSupervisor},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct JobOwner {
    scope: ReadScope,
    root: PathBuf,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    owner: JobOwner,
    job_id: JobId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Read {
    owner: JobOwner,
    job_id: JobId,
    stream: OutputStream,
    cursor: ByteOffset,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Write {
    owner: JobOwner,
    job_id: JobId,
    text: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    owner: JobOwner,
}

struct Job {
    owner: JobOwner,
    run: Box<RunHandle>,
    result: Option<ProcessResult>,
}
#[derive(Default)]
pub(super) struct Jobs {
    records: HashMap<JobId, Job>,
    io: io::Requests,
    closing: bool,
}
impl Jobs {
    pub fn contains_request(&self, id: &RpcId) -> bool {
        self.io.contains(id)
    }
    pub fn cancel_request(&mut self, id: &RpcId) {
        self.io.cancel(id);
    }
    pub fn is_idle(&self) -> bool {
        self.io.is_empty() && self.records.values().all(|job| job.result.is_some())
    }
    pub fn cancel_all(&mut self) {
        self.closing = true;
    }
    pub fn admission(&self, application: &ApplicationId) -> Result<(), CoreError> {
        if self.closing || self.records.len() >= limits::JOBS {
            return Err(CoreError::Limit);
        }
        if self
            .records
            .values()
            .filter(|job| job.result.is_none() && &job.owner.scope.application_id == application)
            .count()
            >= limits::APPLICATION_JOBS
        {
            return Err(CoreError::Limit);
        }
        Ok(())
    }
    pub fn register(
        &mut self,
        scope: ReadScope,
        run: Box<RunHandle>,
        id: JobId,
        supervisor: &ProcessSupervisor,
    ) -> Result<Value, CoreError> {
        let pid = supervisor.process_id(&run, &id)?;
        let root = run.settings().workspace.path().to_owned();
        self.records.insert(
            id.clone(),
            Job {
                owner: JobOwner { scope, root },
                run,
                result: None,
            },
        );
        Ok(json!({"job_id":id,"process_id":pid,"state":"running"}))
    }
    fn owned(&self, owner: &JobOwner, id: &JobId) -> Result<&Job, CoreError> {
        self.records
            .get(id)
            .filter(|job| job.owner.scope == owner.scope && job.owner.root == owner.root)
            .ok_or(CoreError::StaleOwner)
    }
    pub fn rpc(
        &mut self,
        host: &Host,
        supervisor: &mut ProcessSupervisor,
        id: RpcId,
        method: &str,
        params: Value,
    ) -> Result<Option<Value>, Fault> {
        self.dispatch(host, supervisor, id, method, params)
            .map_err(super::fault)
    }
    fn dispatch(
        &mut self,
        host: &Host,
        supervisor: &mut ProcessSupervisor,
        id: RpcId,
        method: &str,
        params: Value,
    ) -> Result<Option<Value>, CoreError> {
        match method {
            methods::JOB_LIST => {
                let request: List = parse(params)?;
                check_owner(host, &request.owner)?;
                let mut jobs = Vec::new();
                for (id, job) in &self.records {
                    if job.owner.scope == request.owner.scope
                        && job.owner.root == request.owner.root
                    {
                        jobs.push(snapshot(id, job, supervisor)?);
                    }
                }
                Ok(Some(json!({"jobs":jobs})))
            }
            methods::JOB_READ => {
                let request: Read = parse(params)?;
                check_owner(host, &request.owner)?;
                self.owned(&request.owner, &request.job_id)?;
                let limit = ByteLimit::try_from(
                    host.frame_limit()
                        .as_usize()
                        .saturating_sub(512)
                        .checked_div(4)
                        .ok_or(CoreError::ArithmeticOverflow)?
                        .min(limits::PROCESS_PAGE_BYTES),
                )?;
                self.io.read(
                    id,
                    request.owner,
                    request.job_id,
                    request.stream,
                    request.cursor,
                    limit,
                )?;
                Ok(None)
            }
            methods::JOB_WRITE => {
                let request: Write = parse(params)?;
                check_owner(host, &request.owner)?;
                let input = InputChunk::try_from(request.text.into_bytes())?;
                let mut io = std::mem::take(&mut self.io);
                let result = io.input(
                    id,
                    request.owner,
                    request.job_id,
                    Some(input),
                    self,
                    supervisor,
                );
                self.io = io;
                result?;
                Ok(None)
            }
            _ => self.query(host, supervisor, id, method, params),
        }
    }
    fn query(
        &mut self,
        host: &Host,
        supervisor: &mut ProcessSupervisor,
        id: RpcId,
        method: &str,
        params: Value,
    ) -> Result<Option<Value>, CoreError> {
        let request: Query = parse(params)?;
        check_owner(host, &request.owner)?;
        let job = self.owned(&request.owner, &request.job_id)?;
        match method {
            methods::JOB_STATUS => Ok(Some(snapshot(&request.job_id, job, supervisor)?)),
            methods::JOB_CANCEL => {
                supervisor.cancel(&job.run, &request.job_id)?;
                Ok(Some(json!({"state":"cancelling"})))
            }
            methods::JOB_FORGET => {
                if job.result.is_none() {
                    return Err(CoreError::Busy);
                }
                supervisor.forget(&job.run, &request.job_id)?;
                self.records.remove(&request.job_id);
                Ok(Some(json!({"forgotten":true})))
            }
            methods::JOB_EOF => {
                let mut io = std::mem::take(&mut self.io);
                let result = io.input(id, request.owner, request.job_id, None, self, supervisor);
                self.io = io;
                result?;
                Ok(None)
            }
            _ => Err(CoreError::Unavailable),
        }
    }
    pub fn tick(
        &mut self,
        host: &mut Host,
        supervisor: &mut ProcessSupervisor,
    ) -> Result<Vec<Value>, CoreError> {
        let ids: Vec<_> = self.records.keys().cloned().collect();
        for id in ids {
            self.sweep(host, supervisor, &id)?;
        }
        let mut io = std::mem::take(&mut self.io);
        let replies = io.tick(host, self, supervisor);
        self.io = io;
        Ok(replies)
    }
    fn sweep(
        &mut self,
        host: &mut Host,
        supervisor: &mut ProcessSupervisor,
        id: &JobId,
    ) -> Result<(), CoreError> {
        let job = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        let live_owner = host.owns_read_scope(&job.owner.scope) && !self.closing;
        if job.result.is_none() {
            if !live_owner {
                host.actor_mut(&job.owner.scope)?.cancel(&job.run)?;
            }
            if supervisor.status(&job.run, id)? == JobStatus::CompletionReady {
                let Some(completion) = supervisor.try_wait(&job.run, id)? else {
                    return Ok(());
                };
                job.result = Some(completion.deliver(host.actor_mut(&job.owner.scope)?)?);
                host.actor_mut(&job.owner.scope)?.finish(&job.run)?;
            }
        }
        if !live_owner && job.result.is_some() {
            supervisor.forget(&job.run, id)?;
            self.records.remove(id);
        }
        Ok(())
    }
}

fn parse<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, CoreError> {
    serde_json::from_value(params).map_err(|_| CoreError::InvalidValue {
        field: "JobRequest",
    })
}
fn check_owner(host: &Host, owner: &JobOwner) -> Result<(), CoreError> {
    if !host.owns_read_scope(&owner.scope) {
        return Err(CoreError::StaleOwner);
    }
    if !owner.root.is_absolute()
        || owner
            .root
            .components()
            .any(|c| c == std::path::Component::ParentDir)
    {
        return Err(CoreError::Rejected);
    }
    Ok(())
}
fn snapshot(id: &JobId, job: &Job, supervisor: &ProcessSupervisor) -> Result<Value, CoreError> {
    let state = if job.result.is_some() {
        "exited"
    } else {
        match supervisor.status(&job.run, id)? {
            JobStatus::Cancelling => "cancelling",
            _ => "running",
        }
    };
    Ok(
        json!({"job_id":id,"process_id":supervisor.process_id(&job.run,id)?,"state":state,"result":job.result}),
    )
}
