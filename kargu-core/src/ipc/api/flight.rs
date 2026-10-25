//! Heterogeneous mailbox storage; each variant retains its own resource phase.

use super::{Completion, RpcId, budget, retry::Operation};
use crate::{
    api::resilience::exchange, application::budget::ObservedUsage, domain::Deadline,
    error::CoreError,
};

pub(super) enum Flight {
    Single(Option<budget::Charge>),
    Attempt(Operation<exchange::Attempt<budget::Charge>>),
    Backoff(Operation<exchange::Backoff>),
    Observing(Operation<exchange::Observing<RpcId>>),
}
impl Flight {
    pub fn charge(&self) -> Option<&budget::Charge> {
        match self {
            Self::Single(charge) => charge.as_ref(),
            Self::Attempt(operation) => Some(operation.phase.ticket()),
            Self::Backoff(_) | Self::Observing(_) => None,
        }
    }
    pub fn deadline(&self) -> Option<Deadline> {
        match self {
            Self::Single(charge) => charge.as_ref().map(|charge| charge.deadline),
            Self::Attempt(operation) => Some(operation.intent.deadline),
            Self::Backoff(operation) => Some(operation.intent.deadline),
            Self::Observing(operation) => Some(operation.intent.deadline),
        }
    }
    pub fn retrying(&self) -> bool {
        !matches!(self, Self::Single(_))
    }
    /// Connection teardown only: every associated worker has actually joined.
    /// Reverse calls are revoked by the connection's pending-request teardown.
    pub fn drained(self) -> Option<budget::Charge> {
        match self {
            Self::Single(charge) => charge,
            Self::Attempt(operation) => Some(operation.phase.retire().0),
            Self::Backoff(operation) => {
                let _ = operation.phase.retire();
                None
            }
            Self::Observing(operation) => {
                let _ = operation.phase.retire();
                None
            }
        }
    }
    pub fn collect_during_drain(
        self,
        completion: Completion,
    ) -> Result<(Option<budget::Charge>, ObservedUsage), CoreError> {
        let usage = match (&self, completion) {
            (Self::Single(_) | Self::Attempt(_), Completion::Attempt(outcome)) => outcome.usage,
            (Self::Backoff(_), Completion::Backoff(_))
            | (Self::Observing(_), Completion::Observed(_)) => ObservedUsage::default(),
            _ => return Err(CoreError::CleanupFailed),
        };
        Ok((self.drained(), usage))
    }
}
