//! Take-once reverse request correlation. Owned by one connection actor.

use super::{MAX_PENDING, protocol::RpcId};
use crate::domain::RequestScope;
use serde_json::Value;
use std::collections::HashMap;
use tokio::sync::oneshot;
use tokio::time::Instant;

/// Terminal failure of a pending reverse call.
#[derive(Debug, thiserror::Error)]
pub enum PendingFailure {
    /// The peer returned a structured error.
    #[error("remote request failed")]
    Remote(Value),
    /// The deadline elapsed.
    #[error("request timed out")]
    Timeout,
    /// The owner cancelled the call.
    #[error("request cancelled")]
    Cancelled,
    /// Connection closure revoked the call.
    #[error("connection closed")]
    Disconnected,
}

/// Request registration errors never replace an existing sender.
#[derive(Debug, thiserror::Error)]
pub enum RegisterError {
    /// An identity is already in flight.
    #[error("duplicate request identity")]
    Duplicate,
    /// The bounded registry is full.
    #[error("pending request capacity reached")]
    Full,
}

/// Outcome delivered exactly once to a reverse-call waiter.
pub type PendingOutcome = Result<Value, PendingFailure>;

struct Entry {
    scope: RequestScope,
    deadline: Instant,
    sender: oneshot::Sender<PendingOutcome>,
}

/// Per-connection correlation table; dropping it disconnects all receivers.
#[derive(Default)]
pub struct PendingRequests {
    entries: HashMap<RpcId, Entry>,
}

impl Drop for PendingRequests {
    fn drop(&mut self) {
        self.disconnect();
    }
}

impl PendingRequests {
    /// Register before sending, retaining the original owner and deadline.
    pub fn register(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        deadline: Instant,
    ) -> Result<oneshot::Receiver<PendingOutcome>, RegisterError> {
        if self.entries.contains_key(&id) {
            return Err(RegisterError::Duplicate);
        }
        if self.entries.len() >= MAX_PENDING {
            return Err(RegisterError::Full);
        }
        let (sender, receiver) = oneshot::channel();
        self.entries.insert(
            id,
            Entry {
                scope,
                deadline,
                sender,
            },
        );
        Ok(receiver)
    }

    /// Resolve once; unknown/late responses have no effect.
    pub fn resolve(&mut self, id: &RpcId, result: Result<Value, Value>) {
        if let Some(entry) = self.entries.remove(id) {
            let outcome = if Instant::now() >= entry.deadline {
                Err(PendingFailure::Timeout)
            } else {
                result.map_err(PendingFailure::Remote)
            };
            let _ = entry.sender.send(outcome);
        }
    }

    /// Cancel only a request belonging to the supplied scope.
    pub fn cancel(&mut self, id: &RpcId, scope: &RequestScope) {
        if self
            .entries
            .get(id)
            .is_some_and(|entry| &entry.scope == scope)
            && let Some(entry) = self.entries.remove(id)
        {
            let _ = entry.sender.send(Err(PendingFailure::Cancelled));
        }
    }

    /// Expire timers and abandoned receivers without retaining their owners.
    pub fn expire(&mut self, now: Instant) {
        self.entries.retain(|_, entry| !entry.sender.is_closed());
        let expired: Vec<_> = self
            .entries
            .iter()
            .filter(|(_, entry)| now >= entry.deadline)
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            if let Some(entry) = self.entries.remove(&id) {
                let _ = entry.sender.send(Err(PendingFailure::Timeout));
            }
        }
    }

    /// Disconnect every waiter on EOF, shutdown or write failure.
    pub fn disconnect(&mut self) {
        for (_, entry) in self.entries.drain() {
            let _ = entry.sender.send(Err(PendingFailure::Disconnected));
        }
    }

    /// Number of retained senders.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether all waiters have been released.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}
