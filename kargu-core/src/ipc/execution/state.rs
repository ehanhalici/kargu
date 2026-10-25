//! Resource-owning command phases. No registry entry has an absent stage.

use super::{input::Prepared, reply::Reply};
use crate::{
    application::{RunHandle, RunPurpose, host::ReadScope},
    domain::JobId,
    error::CoreError,
    ipc::{pending::PendingOutcome, protocol::RpcId},
    security::ApprovalRequest,
};
use serde_json::Value;
use tokio::{sync::oneshot, task::JoinHandle};

pub(super) struct Owner {
    pub purpose: RunPurpose,
    pub scope: ReadScope,
    pub terminal: Option<CoreError>,
}
pub(super) struct Preparing {
    pub task: JoinHandle<Result<Prepared, CoreError>>,
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
    pub reply: Reply,
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
pub(super) enum Stage {
    Preparing(Operation<Preparing>),
    Review(Operation<Reviewing>),
    Running(Operation<Running>),
}
impl Stage {
    pub fn owner(&self) -> &Owner {
        match self {
            Self::Preparing(op) => &op.owner,
            Self::Review(op) => &op.owner,
            Self::Running(op) => &op.owner,
        }
    }
    pub fn owner_mut(&mut self) -> &mut Owner {
        match self {
            Self::Preparing(op) => &mut op.owner,
            Self::Review(op) => &mut op.owner,
            Self::Running(op) => &mut op.owner,
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
