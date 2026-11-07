//! Take-once reverse request correlation. Owned by one connection actor.

use super::{MAX_PENDING, protocol::RpcId};
use crate::{
    application::{ClaimLease, RunClaim, RunScope},
    domain::{CredentialCaptureId, RequestScope, ToolCallId},
    error::CoreError,
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
    /// A preparation cannot begin after its reverse observation deadline.
    #[error("reverse request deadline elapsed")]
    Expired,
    /// A revoked or expired native claim cannot acquire a preparation lease.
    #[error("preparation claim unavailable")]
    Inactive(#[source] CoreError),
}

/// Outcome delivered exactly once to a reverse-call waiter.
pub type PendingOutcome = Result<Value, PendingFailure>;

enum CompletionOwner {
    Tool {
        scope: RunScope,
        call: ToolCallId,
    },
    Preparation {
        claim: RunClaim,
        capture: CredentialCaptureId,
        _lease: ClaimLease,
    },
}
impl CompletionOwner {
    fn accepts(&self, result: &Result<Value, Value>) -> bool {
        let Ok(value) = result else {
            return false;
        };
        let actual = value
            .get("scope")
            .cloned()
            .and_then(|scope| serde_json::from_value::<RunScope>(scope).ok());
        let (scope, identity_matches) = match self {
            Self::Tool { scope, call } => (
                scope,
                value.get("call_id").and_then(Value::as_str) == Some(call.as_str()),
            ),
            Self::Preparation { claim, capture, .. } => (
                claim.scope(),
                value.get("capture_id").and_then(Value::as_str) == Some(capture.as_str()),
            ),
        };
        value.get("quiescent").and_then(Value::as_bool) == Some(true)
            && actual.as_ref() == Some(scope)
            && identity_matches
    }
    fn preparation_failure(&self) -> Option<PendingFailure> {
        match self {
            Self::Preparation { claim, .. } => claim.check_live().err().map(|error| {
                if matches!(error, CoreError::Deadline) {
                    PendingFailure::Timeout
                } else {
                    PendingFailure::Cancelled
                }
            }),
            Self::Tool { .. } => None,
        }
    }
}

struct Entry {
    scope: RequestScope,
    deadline: Instant,
    sender: oneshot::Sender<PendingOutcome>,
    // An issued editor effect outlives its RPC observation deadline. Only an
    // explicit quiescent completion or connection loss releases its waiter.
    effect: Option<CompletionOwner>,
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
        self.insert(
            id,
            scope,
            deadline,
            Some(CompletionOwner::Tool { scope: run, call }),
        )
    }

    /// Register credential IO under an actual claim before issuing the editor request.
    /// The table owns its lease through quiescence or disconnect, even if the
    /// observer is dropped. A receipt is minted here and cannot be reused by callers.
    /// Completion is not activation authority; the consumer must recheck the claim
    /// and its config/selection/target before adopting a returned credential.
    pub fn register_preparation(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        deadline: Instant,
        claim: &RunClaim,
    ) -> Result<(CredentialCaptureId, oneshot::Receiver<PendingOutcome>), RegisterError> {
        if Instant::now() >= deadline {
            return Err(RegisterError::Expired);
        }
        let lease = claim.lease().map_err(RegisterError::Inactive)?;
        let capture = CredentialCaptureId::new();
        let receiver = self.insert(
            id,
            scope,
            deadline,
            Some(CompletionOwner::Preparation {
                claim: claim.clone(),
                capture: capture.clone(),
                _lease: lease,
            }),
        )?;
        Ok((capture, receiver))
    }

    fn insert(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        deadline: Instant,
        effect: Option<CompletionOwner>,
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
        if self
            .entries
            .get(id)
            .and_then(|entry| entry.effect.as_ref())
            .is_some_and(|owner| !owner.accepts(&result))
        {
            // Observation failure or a foreign receipt cannot certify quiescence.
            return;
        }
        if let Some(entry) = self.entries.remove(id) {
            let timed = entry.effect.is_none()
                || matches!(&entry.effect, Some(CompletionOwner::Preparation { .. }));
            let inactive = entry
                .effect
                .as_ref()
                .and_then(CompletionOwner::preparation_failure);
            let outcome = if let Some(failure) = inactive {
                Err(failure)
            } else if timed && Instant::now() >= entry.deadline {
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

    /// Expire observers; preparation activity retains its lease after observer loss.
    pub fn expire(&mut self, now: Instant) {
        self.entries.retain(|_, entry| {
            !entry.sender.is_closed()
                || matches!(&entry.effect, Some(CompletionOwner::Preparation { .. }))
        });
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

#[cfg(test)]
mod preparation_tests {
    use super::*;
    use crate::{
        application::{ApplicationActor, ClaimIntent, Mode, RequestedWorkspace},
        domain::{
            ApplicationId, ClaimId, ConfigRevision, ExecutionTimeout, PolicyRevision, ToolCallLimit,
        },
    };
    use serde_json::json;
    use std::{path::PathBuf, time::Duration};
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn intent() -> Result<ClaimIntent, CoreError> {
        Ok(ClaimIntent {
            mode: Mode::Agent,
            workspace: RequestedWorkspace::try_from(PathBuf::from(
                "/synthetic/credential-workspace",
            ))?,
            tool_limit: ToolCallLimit::try_from(1)?,
            timeout: ExecutionTimeout::try_from(Duration::from_secs(30))?,
            config_revision: ConfigRevision::try_from(1)?,
            policy_revision: PolicyRevision::try_from(1)?,
        })
    }
    fn claimed() -> Result<(ApplicationActor, RunClaim), Box<dyn std::error::Error>> {
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let claim = actor.claim_run(&session, intent()?)?;
        Ok((actor, claim))
    }
    fn receipt(claim: &RunClaim, capture: &CredentialCaptureId) -> Value {
        json!({"scope":claim.scope(),"capture_id":capture,"quiescent":true,
            "credential":"synthetic-private-key"})
    }

    #[tokio::test(start_paused = true)]
    async fn observer_loss_and_forged_completion_cannot_release_the_claim() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let id = RpcId::String("credential-observer".to_owned());
        let connection = RequestScope::try_from("credential-epoch".to_owned())?;
        let (capture, receiver) = pending.register_preparation(
            id.clone(),
            connection,
            Instant::now() + Duration::from_millis(10),
            &claim,
        )?;
        drop(receiver);
        tokio::time::advance(Duration::from_millis(11)).await;
        pending.expire(Instant::now());
        actor.cancel_claim(&claim)?;
        assert!(matches!(actor.finish_claim(&claim), Err(CoreError::Busy)));
        assert!(matches!(
            actor.claim_run(claim.scope().session_id(), intent()?),
            Err(CoreError::Busy)
        ));
        let mut foreign = receipt(&claim, &capture);
        foreign["scope"]["claim_id"] = json!(ClaimId::new());
        let mut unconfirmed = receipt(&claim, &capture);
        unconfirmed["quiescent"] = json!(false);
        for invalid in [
            Err(json!({"code":-32000,"message":"observer cancelled"})),
            Ok(foreign),
            Ok(unconfirmed),
            Ok(receipt(&claim, &CredentialCaptureId::new())),
            Ok(json!({"scope":claim.scope(),"call_id":ToolCallId::new(),"quiescent":true})),
        ] {
            pending.resolve(&id, invalid);
            pending.expire(Instant::now());
            assert_eq!(pending.len(), 1);
            assert!(!claim.drained());
        }
        pending.resolve(&id, Ok(receipt(&claim, &capture)));
        assert!(pending.is_empty());
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        let next = actor.claim_run(claim.scope().session_id(), intent()?)?;
        actor.finish_claim(&next)?;
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn late_quiescence_drains_but_does_not_deliver_a_late_credential() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let id = RpcId::Integer(1);
        let (capture, mut receiver) = pending.register_preparation(
            id.clone(),
            RequestScope::try_from("epoch".to_owned())?,
            Instant::now() + Duration::from_millis(10),
            &claim,
        )?;
        tokio::time::advance(Duration::from_millis(11)).await;
        pending.expire(Instant::now());
        assert!(matches!(
            receiver.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert!(!claim.drained());
        pending.resolve(&id, Ok(receipt(&claim, &capture)));
        assert!(matches!(receiver.await?, Err(PendingFailure::Timeout)));
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        Ok(())
    }

    #[tokio::test]
    async fn cancelled_claim_drains_without_delivering_its_credential() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let id = RpcId::Integer(1);
        let (capture, receiver) = pending.register_preparation(
            id.clone(),
            RequestScope::try_from("epoch".to_owned())?,
            Instant::now() + Duration::from_secs(5),
            &claim,
        )?;
        actor.cancel_claim(&claim)?;
        assert!(matches!(actor.finish_claim(&claim), Err(CoreError::Busy)));
        pending.resolve(&id, Ok(receipt(&claim, &capture)));
        assert!(matches!(receiver.await?, Err(PendingFailure::Cancelled)));
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        Ok(())
    }

    #[tokio::test]
    async fn receipts_are_take_once_and_cannot_match_the_next_capture() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let connection = RequestScope::try_from("epoch".to_owned())?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let first = RpcId::Integer(1);
        let (capture, receiver) =
            pending.register_preparation(first.clone(), connection.clone(), deadline, &claim)?;
        let old = receipt(&claim, &capture);
        pending.resolve(&first, Ok(old.clone()));
        assert_eq!(receiver.await??["capture_id"], json!(capture));
        pending.resolve(&first, Ok(old.clone()));
        assert!(pending.is_empty());
        assert!(claim.drained());
        let second = RpcId::Integer(2);
        let (next_capture, receiver) =
            pending.register_preparation(second.clone(), connection, deadline, &claim)?;
        assert_ne!(next_capture, capture);
        pending.resolve(&second, Ok(old));
        assert_eq!(pending.len(), 1);
        assert!(!claim.drained());
        pending.resolve(&second, Ok(receipt(&claim, &next_capture)));
        assert_eq!(receiver.await??["capture_id"], json!(next_capture));
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        Ok(())
    }

    #[tokio::test]
    async fn full_registry_and_table_drop_leave_no_preparation_lease_behind() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let connection = RequestScope::try_from("epoch".to_owned())?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut observers = Vec::new();
        for index in 0..MAX_PENDING {
            observers.push(pending.register(
                RpcId::String(format!("observer-{index}")),
                connection.clone(),
                deadline,
            )?);
        }
        assert!(matches!(
            pending.register_preparation(RpcId::Integer(1), connection.clone(), deadline, &claim),
            Err(RegisterError::Full)
        ));
        assert!(claim.drained());
        pending.disconnect();
        let (_, receiver) =
            pending.register_preparation(RpcId::Integer(2), connection, deadline, &claim)?;
        assert!(!claim.drained());
        drop(pending);
        assert!(matches!(receiver.await?, Err(PendingFailure::Disconnected)));
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        Ok(())
    }

    #[tokio::test]
    async fn rollback_disconnect_and_failed_registration_do_not_leak_claim_leases() -> TestResult {
        let (mut actor, claim) = claimed()?;
        let mut pending = PendingRequests::default();
        let connection = RequestScope::try_from("epoch".to_owned())?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let (capture, receiver) = pending.register_preparation(
            RpcId::Integer(1),
            connection.clone(),
            deadline,
            &claim,
        )?;
        assert!(matches!(
            pending.register_preparation(RpcId::Integer(1), connection.clone(), deadline, &claim),
            Err(RegisterError::Duplicate)
        ));
        pending.remove_unissued_effect(
            &RpcId::Integer(1),
            &RequestScope::try_from("foreign".to_owned())?,
        );
        assert!(!claim.drained());
        pending.remove_unissued_effect(&RpcId::Integer(1), &connection);
        assert!(matches!(receiver.await?, Err(PendingFailure::Cancelled)));
        assert!(claim.drained());
        let (_, receiver) = pending.register_preparation(
            RpcId::Integer(2),
            connection.clone(),
            deadline,
            &claim,
        )?;
        pending.disconnect();
        assert!(matches!(receiver.await?, Err(PendingFailure::Disconnected)));
        pending.resolve(&RpcId::Integer(2), Ok(receipt(&claim, &capture)));
        assert!(claim.drained());
        assert!(matches!(
            pending.register_preparation(
                RpcId::Integer(3),
                connection.clone(),
                Instant::now(),
                &claim
            ),
            Err(RegisterError::Expired)
        ));
        actor.cancel_claim(&claim)?;
        assert!(matches!(
            pending.register_preparation(RpcId::Integer(4), connection, deadline, &claim),
            Err(RegisterError::Inactive(CoreError::Cancelled))
        ));
        assert!(claim.drained());
        actor.finish_claim(&claim)?;
        Ok(())
    }
}
