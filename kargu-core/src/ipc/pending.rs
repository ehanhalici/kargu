//! Take-once reverse request correlation. Owned by one connection actor.

use super::{MAX_PENDING, protocol::RpcId};
use crate::{
    application::RunScope,
    domain::{RequestScope, ToolCallId},
};
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
    // An issued editor effect outlives its RPC observation deadline. Only an
    // explicit quiescent completion or connection loss releases its waiter.
    effect: Option<(RunScope, ToolCallId)>,
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
        self.insert(id, scope, deadline, None)
    }

    /// Retain actual editor activity through cancellation and timer expiry.
    /// The controller sends cancellation separately and continues draining.
    pub(crate) fn register_effect(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        deadline: Instant,
        run: RunScope,
        call: ToolCallId,
    ) -> Result<oneshot::Receiver<PendingOutcome>, RegisterError> {
        self.insert(id, scope, deadline, Some((run, call)))
    }

    fn insert(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        deadline: Instant,
        effect: Option<(RunScope, ToolCallId)>,
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
                effect,
            },
        );
        Ok(receiver)
    }

    /// Resolve once; unknown/late responses have no effect.
    pub fn resolve(&mut self, id: &RpcId, result: Result<Value, Value>) {
        if let Some((scope, call)) = self.entries.get(id).and_then(|entry| entry.effect.as_ref())
            && !matches!(&result, Ok(value) if
                value.get("quiescent").and_then(Value::as_bool) == Some(true)
                && value.get("scope").cloned().and_then(|value| serde_json::from_value::<RunScope>(value).ok()).as_ref() == Some(scope)
                && value.get("call_id").and_then(Value::as_str) == Some(call.as_str()))
        {
            // An error/invalid reply cannot certify that a delegated effect
            // stopped. Keep its resource ticket for cancel/actual completion.
            return;
        }
        if let Some(entry) = self.entries.remove(id) {
            let outcome = if entry.effect.is_none() && Instant::now() >= entry.deadline {
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
            .is_some_and(|entry| &entry.scope == scope && entry.effect.is_none())
            && let Some(entry) = self.entries.remove(id)
        {
            let _ = entry.sender.send(Err(PendingFailure::Cancelled));
        }
    }

    /// Roll back correlation when issuance failed before the request was queued.
    pub(crate) fn remove_unissued_effect(&mut self, id: &RpcId, scope: &RequestScope) {
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
            .filter(|(_, entry)| entry.effect.is_none() && now >= entry.deadline)
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

#[cfg(test)]
mod effect_tests {
    use super::*;
    use crate::domain::{ApplicationId, ClaimId, RunId, SessionId};
    use serde_json::json;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test(start_paused = true)]
    async fn issued_effect_expiry_and_cancel_do_not_release_actual_activity() -> TestResult {
        let mut requests = PendingRequests::default();
        let id = RpcId::String("issued-editor".to_owned());
        let connection = RequestScope::try_from("conn-1".to_owned())?;
        let scope: RunScope = serde_json::from_value(json!({"purpose":"agent_turn",
            "application_id":ApplicationId::new(),"session_id":SessionId::new(),
            "run_id":RunId::new(),"claim_id":ClaimId::new(),"generation":1,
            "config_revision":1,"policy_revision":1}))?;
        let call = ToolCallId::new();
        let deadline = Instant::now() + std::time::Duration::from_millis(10);
        let mut receiver = requests.register_effect(
            id.clone(),
            connection.clone(),
            deadline,
            scope.clone(),
            call.clone(),
        )?;
        tokio::time::advance(std::time::Duration::from_millis(11)).await;
        requests.expire(Instant::now());
        requests.cancel(&id, &connection);
        requests.resolve(
            &id,
            Err(json!({"code":-32000,"message":"observer timeout"})),
        );
        assert_eq!(requests.len(), 1);
        assert!(matches!(
            receiver.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        requests.resolve(
            &id,
            Ok(json!({"scope":scope,"call_id":ToolCallId::new(),"quiescent":true})),
        );
        assert_eq!(requests.len(), 1);
        requests.resolve(
            &id,
            Ok(json!({"scope":scope,"call_id":call,"quiescent":true,
            "outcome":"outcome_unknown","text":"interrupted after issue"})),
        );
        let completion = receiver.await??;
        assert_eq!(
            completion.get("quiescent").and_then(Value::as_bool),
            Some(true)
        );
        assert!(requests.is_empty());
        Ok(())
    }
}
