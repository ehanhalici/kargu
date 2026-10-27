//! Resource-owning command phases. No registry entry has an absent stage.

use super::{
    input::Prepared,
    reply::{CompletedReply, Reply, RunningReply},
};
use crate::workspace::command::Preparation;
use crate::{
    application::{RunHandle, RunPurpose, host::ReadScope},
    domain::JobId,
    error::CoreError,
    ipc::{pending::PendingOutcome, protocol::RpcId},
    process::{CapturedOutput, JobCompletion},
    security::ApprovalRequest,
};
use serde_json::Value;
use std::time::Instant;
use tokio::{sync::oneshot, task::JoinHandle};
use tokio_util::sync::{CancellationToken, DropGuard};

pub(super) struct Owner {
    pub mutation_issued: bool,
    pub purpose: RunPurpose,
    pub scope: ReadScope,
    pub terminal: Option<CoreError>,
}
pub(super) struct Preparing {
    pub task: JoinHandle<Result<Prepared, CoreError>>,
    pub cancel: CancellationToken,
    pub deadline: Instant,
    _guard: DropGuard,
}
impl Preparing {
    pub fn spawn(
        prepare: impl FnOnce(&Preparation) -> Result<Prepared, CoreError> + Send + 'static,
    ) -> Result<Self, CoreError> {
        let context = Preparation::new()?;
        let cancel = context.cancellation().clone();
        let deadline = context.deadline();
        let guard = cancel.clone().drop_guard();
        let task = tokio::task::spawn_blocking(move || {
            context.check()?;
            let result = prepare(&context);
            if let Err(error) = context.check() {
                if let Ok(prepared) = result {
                    prepared.discard()?;
                }
                return Err(error);
            }
            result
        });
        Ok(Self {
            task,
            cancel,
            deadline,
            _guard: guard,
        })
    }
}
pub(super) struct ApprovalReady {
    pub run: Box<RunHandle>,
    pub request: Box<ApprovalRequest>,
    pub reply: Reply,
}
pub(super) struct Reviewing {
    pub prepared: ApprovalReady,
    pub reverse: RpcId,
    pub receiver: oneshot::Receiver<PendingOutcome>,
}
pub(super) struct Running {
    pub run: Box<RunHandle>,
    pub job: JobId,
    pub reply: RunningReply,
}
pub(super) struct Finalizing {
    pub run: Box<RunHandle>,
    pub job: JobId,
    pub task: JoinHandle<(JobCompletion, Result<CompletedReply, CoreError>)>,
}
pub(super) struct Discarding {
    pub run: Option<Box<RunHandle>>,
    pub error: CoreError,
    pub task: JoinHandle<Result<(), CoreError>>,
}
#[must_use = "Retain command resources until their phase has actually drained"]
pub(super) struct Operation<Phase> {
    pub owner: Owner,
    pub phase: Phase,
}
impl<Phase> Operation<Phase> {
    fn transition<Next>(self, consume: impl FnOnce(Phase) -> Next) -> Operation<Next> {
        Operation {
            owner: self.owner,
            phase: consume(self.phase),
        }
    }
}
impl Operation<Preparing> {
    pub fn prepared(self, prepared: Prepared) -> Operation<Prepared> {
        self.transition(|_| prepared)
    }
}
impl Operation<ApprovalReady> {
    pub fn review(
        self,
        reverse: RpcId,
        receiver: oneshot::Receiver<PendingOutcome>,
    ) -> Operation<Reviewing> {
        self.transition(|prepared| Reviewing {
            prepared,
            reverse,
            receiver,
        })
    }
}
impl Operation<Reviewing> {
    pub fn reviewed(self) -> Operation<ApprovalReady> {
        self.transition(|review| review.prepared)
    }
}
impl Operation<Running> {
    pub fn finalizing(
        self,
        completion: JobCompletion,
        output: CapturedOutput,
    ) -> Operation<Finalizing> {
        self.transition(|Running { run, job, reply }| Finalizing {
            run,
            job,
            task: tokio::task::spawn_blocking(move || {
                let result = reply.complete(completion.result(), output);
                (completion, result)
            }),
        })
    }
}
pub(super) enum Stage {
    Preparing(Operation<Preparing>),
    Review(Operation<Reviewing>),
    Running(Operation<Running>),
    Finalizing(Operation<Finalizing>),
    Discarding(Operation<Discarding>),
}
impl Stage {
    pub fn owner(&self) -> &Owner {
        match self {
            Self::Preparing(op) => &op.owner,
            Self::Review(op) => &op.owner,
            Self::Running(op) => &op.owner,
            Self::Finalizing(op) => &op.owner,
            Self::Discarding(op) => &op.owner,
        }
    }
    pub fn owner_mut(&mut self) -> &mut Owner {
        match self {
            Self::Preparing(op) => &mut op.owner,
            Self::Review(op) => &mut op.owner,
            Self::Running(op) => &mut op.owner,
            Self::Finalizing(op) => &mut op.owner,
            Self::Discarding(op) => &mut op.owner,
        }
    }
}
pub(super) enum Progress {
    Pending(Stage),
    Done(Owner, Result<Value, CoreError>),
}
impl Owner {
    pub fn complete(self, result: Result<Value, CoreError>) -> Progress {
        Progress::Done(self, result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn cancelling_or_dropping_preparation_revokes_the_actual_owned_worker()
    -> Result<(), Box<dyn std::error::Error>> {
        for drop_phase in [false, true] {
            let (entered, ready) = oneshot::channel();
            let (stopped, joined) = oneshot::channel();
            let phase = Preparing::spawn(move |context| {
                let _ = entered.send(());
                while context.check().is_ok() {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                let _ = stopped.send(());
                Err(CoreError::Cancelled)
            })?;
            ready.await?;
            if drop_phase {
                drop(phase);
            } else {
                phase.cancel.cancel();
                assert!(matches!(phase.task.await?, Err(CoreError::Cancelled)));
            }
            tokio::time::timeout(std::time::Duration::from_secs(1), joined).await??;
        }
        Ok(())
    }
}
