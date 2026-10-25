//! Captured retry intent and resource phases. Only the parent mailbox grants IO.

use super::{
    ApiError, ApiRequests, Completion, HttpRequest, Pending, PendingRequests, RpcId, budget,
    protocol, worker,
};
use crate::{
    api::resilience::{Publication, RetryDecision, RetryPolicy},
    application::host::Host,
    domain::{Deadline, RetryAttempt},
    error::CoreError,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, SystemTime},
};
use tokio::time::Instant;

/// Explicit headless mode never silently bypasses a configured editor observer.
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Observer {
    None,
    Editor,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Configuration {
    pub policy: RetryPolicy,
    pub observer: Observer,
    #[serde(default)]
    pub circuit: Option<crate::api::resilience::CircuitPolicy>,
}
pub(super) enum Stage {
    Attempt,
    Backoff,
    Observing { reverse: RpcId },
}
pub(super) struct Operation {
    pub configuration: Configuration,
    pub arguments: Arc<HttpRequest>,
    pub reference: budget::BudgetRef,
    pub deadline: Deadline,
    pub attempt: RetryAttempt,
    pub stage: Option<Stage>,
    pub page_bytes: usize,
}

impl ApiRequests {
    pub(super) fn completed(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        mut pending: Pending,
        completion: Completion,
    ) -> Result<Option<Value>, CoreError> {
        let stage = pending
            .retry
            .as_mut()
            .map(|operation| operation.stage.take().ok_or(CoreError::CleanupFailed))
            .transpose()?;
        if let Completion::Attempt(outcome) = &completion {
            if !matches!(stage, None | Some(Stage::Attempt)) {
                return Err(CoreError::CleanupFailed);
            }
            if let Some(charge) = pending.charge.take() {
                pending.snapshot = Some(self.budgets.finish(charge, outcome.usage)?);
            }
        }
        if let Some(Stage::Observing {
            reverse: correlation,
        }) = &stage
        {
            reverse.cancel(correlation, &host.request_scope()?);
        }
        if let Some(error) = self.retry_revoked(host, &mut pending) {
            return self.finish(host, id, pending, Err(error));
        }
        match (stage, completion) {
            (None | Some(Stage::Attempt), Completion::Attempt(outcome)) => {
                self.retry_attempt_retired(host, id, pending, outcome)
            }
            (Some(Stage::Backoff), Completion::Backoff(result)) => {
                self.retry_backoff_retired(host, reverse, id, pending, result)
            }
            (Some(Stage::Observing { .. }), Completion::Observed(result)) => match result {
                Ok(true) => self.retry_grant(host, id, pending),
                Ok(false) => self.finish(host, id, pending, Err(ApiError::Cancelled)),
                Err(error) => self.finish(host, id, pending, Err(error)),
            },
            _ => Err(CoreError::CleanupFailed),
        }
    }

    fn retry_revoked(&mut self, host: &Host, pending: &mut Pending) -> Option<ApiError> {
        if let Some(error) = pending.terminal.take() {
            return Some(error);
        }
        if pending.cancel.is_cancelled() || !host.owns_read_scope(&pending.scope) {
            return Some(ApiError::Cancelled);
        }
        if pending
            .retry
            .as_ref()
            .is_some_and(|op| op.deadline.expired())
        {
            // Expiry must be projected even when there is no ticket to finish.
            let _ = self.retry_preflight(host, pending);
            return Some(ApiError::RunDeadline);
        }
        None
    }

    fn retry_attempt_retired(
        &mut self,
        host: &Host,
        id: RpcId,
        pending: Pending,
        outcome: super::Outcome,
    ) -> Result<Option<Value>, CoreError> {
        let Err(error) = outcome.result else {
            return self.finish(host, id, pending, outcome.result);
        };
        let Some(operation) = &pending.retry else {
            return self.finish(host, id, pending, Err(error));
        };
        if !operation.configuration.policy.retryable(&error) {
            return self.finish(host, id, pending, Err(error));
        }
        let decision = operation.configuration.policy.after_failure_observed(
            operation.attempt,
            &error,
            if pending.published {
                Publication::Visible
            } else {
                Publication::Silent
            },
            SystemTime::now(),
            outcome.entropy.unwrap_or(Err(CoreError::Unavailable)),
        );
        match decision {
            Ok(RetryDecision::Wait(delay)) => self.retry_wait(host, id, pending, delay),
            Ok(RetryDecision::Stop(_)) => self.finish(host, id, pending, Err(error)),
            Err(_) => self.finish(host, id, pending, Err(ApiError::RetryUnavailable)),
        }
    }

    fn retry_wait(
        &mut self,
        host: &Host,
        id: RpcId,
        mut pending: Pending,
        delay: crate::api::resilience::RetryDelay,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = self.retry_preflight(host, &mut pending) {
            return self.finish(host, id, pending, Err(error));
        }
        let operation = pending.retry.as_mut().ok_or(CoreError::CleanupFailed)?;
        operation.stage = Some(Stage::Backoff);
        let deadline = operation.deadline;
        let cancel = pending.cancel.clone();
        let work_id = id.clone();
        self.workers.spawn(async move {
            let result = tokio::select! {
                biased;
                _ = cancel.cancelled() => Err(ApiError::Cancelled),
                _ = deadline.elapsed() => Err(ApiError::RunDeadline),
                _ = tokio::time::sleep(delay.duration()) => Ok(()),
            };
            (work_id, Completion::Backoff(result))
        });
        self.pending.insert(id, pending);
        Ok(None)
    }

    fn retry_backoff_retired(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        mut pending: Pending,
        result: Result<(), ApiError>,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = result {
            return self.finish(host, id, pending, Err(error));
        }
        if let Err(error) = self.retry_preflight(host, &mut pending) {
            return self.finish(host, id, pending, Err(error));
        }
        match pending
            .retry
            .as_ref()
            .ok_or(CoreError::CleanupFailed)?
            .configuration
            .observer
        {
            Observer::None => self.retry_grant(host, id, pending),
            Observer::Editor => self.retry_observe(host, reverse, id, pending),
        }
    }

    fn retry_preflight(&mut self, host: &Host, pending: &mut Pending) -> Result<(), ApiError> {
        let operation = pending.retry.as_ref().ok_or(ApiError::RetryUnavailable)?;
        let result = self
            .budgets
            .preflight(host, &pending.scope, &operation.reference);
        pending.snapshot = self.budgets.snapshot(&operation.reference.budget_id);
        result.map_err(admission_failure)
    }

    fn retry_grant(
        &mut self,
        host: &Host,
        id: RpcId,
        mut pending: Pending,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = self.retry_preflight(host, &mut pending) {
            return self.finish(host, id, pending, Err(error));
        }
        let operation = pending.retry.as_mut().ok_or(CoreError::CleanupFailed)?;
        let attempt = operation.attempt.next()?;
        let charge = match self
            .budgets
            .admit_metered(host, &pending.scope, &operation.reference)
        {
            Ok(charge) => charge,
            Err(error) => return self.finish(host, id, pending, Err(admission_failure(error))),
        };
        operation.attempt = attempt;
        operation.stage = Some(Stage::Attempt);
        pending.charge = Some(charge);
        self.workers.spawn(
            worker::Attempt {
                id: id.clone(),
                arguments: operation.arguments.clone(),
                sender: self.sender.clone(),
                cancel: pending.cancel.clone(),
                deadline: Some(operation.deadline),
                page_bytes: operation.page_bytes,
                observe_entropy: true,
                expectation: if operation.configuration.circuit.is_some() {
                    worker::ResponseExpectation::Model
                } else {
                    worker::ResponseExpectation::Raw
                },
            }
            .run(),
        );
        self.pending.insert(id, pending);
        Ok(None)
    }

    fn retry_observe(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        mut pending: Pending,
    ) -> Result<Option<Value>, CoreError> {
        let operation = pending.retry.as_mut().ok_or(CoreError::CleanupFailed)?;
        self.sequence = self.sequence.next()?;
        let correlation = RpcId::String(format!(
            "s:api_retry:{}:{}",
            host.request_scope()?.as_str(),
            self.sequence.as_u64()
        ));
        let message = json!({"jsonrpc":"2.0","id":correlation.value(),"method":"editor/api_retry",
            "params":{"request_id":id.value(),
                "scope":{"application_id":pending.scope.application_id,"session_id":pending.scope.session_id},
                "connection_epoch":host.request_scope()?.as_str(),
                "attempt":operation.attempt.next()?,"budget":pending.snapshot}});
        if message.to_string().len().saturating_add(1) > host.frame_limit().as_usize() {
            return self.finish(host, id, pending, Err(ApiError::RetryUnavailable));
        }
        let deadline = operation.deadline.cap(
            Instant::now()
                .checked_add(Duration::from_secs(10))
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let receiver = match reverse.register(correlation.clone(), host.request_scope()?, deadline)
        {
            Ok(receiver) => receiver,
            Err(_) => return self.finish(host, id, pending, Err(ApiError::RetryUnavailable)),
        };
        operation.stage = Some(Stage::Observing {
            reverse: correlation,
        });
        let budget_deadline = operation.deadline;
        let cancel = pending.cancel.clone();
        let work_id = id.clone();
        self.workers.spawn(async move {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Acknowledgement {
                accepted: bool,
            }
            let result = tokio::select! {
                biased;
                _ = cancel.cancelled() => Err(ApiError::Cancelled),
                _ = budget_deadline.elapsed() => Err(ApiError::RunDeadline),
                _ = tokio::time::sleep_until(deadline) => Err(ApiError::RetryUnavailable),
                reply = receiver => match reply {
                    Ok(Ok(value)) => serde_json::from_value::<Acknowledgement>(value)
                        .map(|ack| ack.accepted).map_err(|_| ApiError::RetryUnavailable),
                    _ => Err(ApiError::RetryUnavailable),
                },
            };
            (work_id, Completion::Observed(result))
        });
        self.pending.insert(id, pending);
        Ok(Some(message))
    }
}

fn admission_failure(error: budget::AdmissionFailure) -> ApiError {
    match error {
        budget::AdmissionFailure::Exhausted(crate::application::budget::Refusal::Deadline) => {
            ApiError::RunDeadline
        }
        budget::AdmissionFailure::Exhausted(reason) => ApiError::BudgetRefused(reason),
        budget::AdmissionFailure::Closed | budget::AdmissionFailure::StaleOwner => {
            ApiError::Cancelled
        }
        _ => ApiError::RetryUnavailable,
    }
}
impl ApiRequests {
    fn finish(
        &mut self,
        host: &Host,
        id: RpcId,
        mut pending: Pending,
        result: Result<Value, ApiError>,
    ) -> Result<Option<Value>, CoreError> {
        let circuit = pending
            .circuit
            .take()
            .map(|grant| self.circuits.finish(grant, Some(&result)))
            .transpose()?;
        let mut payload = match result {
            Ok(value) => value,
            Err(error) => json!({"failure":error.snapshot(),"partial":pending.published}),
        };
        if let Some(snapshot) = pending.snapshot {
            payload["budget"] = snapshot;
        }
        if let Some(circuit) = circuit {
            payload["circuit"] = circuit;
        }
        self.circuits.collect(host);
        Ok(Some(protocol::success(&id, payload)))
    }
}
