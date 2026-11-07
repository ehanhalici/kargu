//! Claim-owned credential reverse IO; observation cancellation is not quiescence.

use super::*;
use crate::{api::SecretString, domain::CredentialCaptureId, ipc::pending::PendingOutcome};
use tokio::{sync::oneshot, time::Instant};

pub(super) struct CredentialPreparation {
    id: RpcId,
    capture: CredentialCaptureId,
    receiver: oneshot::Receiver<PendingOutcome>,
    deadline: Instant,
    cancel_sent: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Outcome {
    Resolved,
    Unavailable,
    Cancelled,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    scope: RunScope,
    capture_id: CredentialCaptureId,
    quiescent: bool,
    outcome: Outcome,
    key: Option<SecretString>,
}
impl CredentialPreparation {
    pub fn start(
        host: &Host,
        pending: &mut PendingRequests,
        forward: &RpcId,
        claim: &RunClaim,
        target: &crate::configuration::policy::RunTarget,
        messages: &mut Vec<Value>,
    ) -> Result<Self, CoreError> {
        let epoch = host.request_scope()?;
        let id = RpcId::String(format!(
            "r:credential:{}:{}",
            epoch.as_str(),
            claim.scope().run_id().as_str()
        ));
        let deadline = claim.deadline().cap(
            Instant::now()
                .checked_add(timeouts::CREDENTIAL_RECEIPT)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let (capture, receiver) = pending
            .register_preparation(id.clone(), epoch.clone(), deadline, claim)
            .map_err(|error| match error {
                crate::ipc::pending::RegisterError::Inactive(error) => error,
                crate::ipc::pending::RegisterError::Expired => CoreError::Deadline,
                crate::ipc::pending::RegisterError::Full => CoreError::Limit,
                crate::ipc::pending::RegisterError::Duplicate => CoreError::Rejected,
            })?;
        let message = match Self::request(host, forward, &id, claim, target, &capture, deadline) {
            Ok(message) => message,
            Err(error) => {
                pending.remove_unissued_effect(&id, &epoch);
                return Err(error);
            }
        };
        messages.push(message);
        Ok(Self {
            id,
            capture,
            receiver,
            deadline,
            cancel_sent: false,
        })
    }
    fn request(
        host: &Host,
        forward: &RpcId,
        id: &RpcId,
        claim: &RunClaim,
        target: &crate::configuration::policy::RunTarget,
        capture: &CredentialCaptureId,
        deadline: Instant,
    ) -> Result<Value, CoreError> {
        let timeout = u64::try_from(
            deadline
                .saturating_duration_since(Instant::now())
                .as_millis(),
        )
        .map_err(|_| CoreError::ArithmeticOverflow)?;
        if timeout == 0 {
            return Err(CoreError::Deadline);
        }
        let message = json!({"jsonrpc":"2.0","id":id.value(),"method":"editor/credential",
            "params":{"request_id":forward.value(),"connection_epoch":host.request_scope()?.as_str(),
            "scope":claim.scope(),"capture_id":capture,"provider":target.provider,
            "host":target.interop_host()?.ok_or(CoreError::Unavailable)?,"timeout_ms":timeout}});
        if message.to_string().len() > host.frame_limit().as_usize() {
            return Err(CoreError::Limit);
        }
        Ok(message)
    }
    pub fn expired(&self) -> bool {
        Instant::now() >= self.deadline
    }
    pub fn poll(
        &mut self,
        host: &Host,
        claim: &RunClaim,
        cancelled: bool,
        messages: &mut Vec<Value>,
    ) -> Result<Option<Result<SecretString, CoreError>>, CoreError> {
        if cancelled && !self.cancel_sent {
            let message = json!({"jsonrpc":"2.0","method":"rpc/cancel",
                "params":{"scope":host.request_scope()?.as_str(),"request_id":self.id.value()}});
            if message.to_string().len() > host.frame_limit().as_usize() {
                return Err(CoreError::Limit);
            }
            self.cancel_sent = true;
            messages.push(message);
        }
        match self.receiver.try_recv() {
            Err(oneshot::error::TryRecvError::Empty) => Ok(None),
            Err(oneshot::error::TryRecvError::Closed) => Ok(Some(Err(CoreError::Cancelled))),
            Ok(Err(crate::ipc::pending::PendingFailure::Timeout)) => {
                Ok(Some(Err(CoreError::Deadline)))
            }
            Ok(Err(_)) => Ok(Some(Err(CoreError::Cancelled))),
            Ok(Ok(value)) => Ok(Some(self.complete(claim, value))),
        }
    }
    fn complete(&self, claim: &RunClaim, value: Value) -> Result<SecretString, CoreError> {
        claim.check_live()?;
        let receipt: Completion =
            serde_json::from_value(value).map_err(|_| CoreError::InvalidToolOutput)?;
        if receipt.scope != *claim.scope()
            || receipt.capture_id != self.capture
            || !receipt.quiescent
        {
            return Err(CoreError::StaleOwner);
        }
        match (receipt.outcome, receipt.key) {
            (Outcome::Resolved, Some(key)) => Ok(key),
            (Outcome::Unavailable, None) => Err(CoreError::Unavailable),
            (Outcome::Cancelled, None) => Err(CoreError::Cancelled),
            _ => Err(CoreError::InvalidToolOutput),
        }
    }
}
