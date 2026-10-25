//! Captured retry intent and resource phases. Only the parent mailbox grants IO.

use super::{
    Active, ApiError, ApiRequests, Completion, HttpRequest, Pending, PendingRequests, RpcId,
    budget, flight::Flight, protocol, worker,
};
use crate::{
    api::resilience::{Publication, RetryDecision, RetryPolicy, exchange},
    application::host::Host,
    domain::{ApiPageBytes, Deadline, RetryAttempt},
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
pub(super) struct Intent {
    pub configuration: Configuration,
    pub arguments: Arc<HttpRequest>,
    pub reference: budget::BudgetRef,
    pub deadline: Deadline,
    pub attempt: RetryAttempt,
    pub page_bytes: ApiPageBytes,
}
#[must_use = "A retry operation retains its resource phase until collection"]
pub(super) struct Operation<Phase> {
    pub intent: Intent,
    pub phase: Phase,
}
impl<Phase> Operation<Phase> {
    fn transition<Next>(self, consume: impl FnOnce(Phase) -> Next) -> Operation<Next> {
        Operation {
            intent: self.intent,
            phase: consume(self.phase),
        }
    }
}
impl Operation<exchange::Retired> {
    fn wait(self) -> Operation<exchange::Backoff> {
        self.transition(exchange::Retired::wait)
    }
}
impl Operation<exchange::Backoff> {
    fn retired(self) -> Operation<exchange::ObserverReady> {
        self.transition(exchange::Backoff::retire)
    }
}
impl Operation<exchange::ObserverReady> {
    fn headless(self) -> Operation<exchange::ReplayReady> {
        self.transition(exchange::ObserverReady::headless)
    }
    fn observe(self, correlation: RpcId) -> Operation<exchange::Observing<RpcId>> {
        self.transition(|phase| phase.observe(correlation))
    }
}
impl Operation<exchange::Observed> {
    fn accepted(self) -> Operation<exchange::ReplayReady> {
        self.transition(exchange::Observed::accepted)
    }
}
impl Operation<exchange::ReplayReady> {
    fn admitted(self, charge: budget::Charge) -> Operation<exchange::Attempt<budget::Charge>> {
        self.transition(|phase| phase.admit(charge))
    }
}
enum Collected {
    Single(super::Outcome),
    Attempt(Operation<exchange::Retired>, super::Outcome),
    Backoff(Operation<exchange::ObserverReady>, Result<(), ApiError>),
    Observed(Operation<exchange::Observed>, Result<bool, ApiError>),
}
impl Collected {
    fn retry_reference(&self) -> Option<&budget::BudgetRef> {
        match self {
            Self::Single(_) => None,
            Self::Attempt(operation, _) => Some(&operation.intent.reference),
            Self::Backoff(operation, _) => Some(&operation.intent.reference),
            Self::Observed(operation, _) => Some(&operation.intent.reference),
        }
    }
}

impl ApiRequests {
    pub(super) fn completed(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        active: Active,
        completion: Completion,
    ) -> Result<Option<Value>, CoreError> {
        let Active {
            mut pending,
            flight,
        } = active;
        let deadline = flight.deadline();
        // Runtime matching belongs only at the external worker-observation
        // boundary. Deterministic transitions below consume typed phases.
        let collected = match (flight, completion) {
            (Flight::Single(charge), Completion::Attempt(outcome)) => {
                if let Some(charge) = charge {
                    pending.snapshot = Some(self.budgets.finish(charge, outcome.usage)?);
                }
                Collected::Single(outcome)
            }
            (Flight::Attempt(operation), Completion::Attempt(outcome)) => {
                let (charge, phase) = operation.phase.retire();
                pending.snapshot = Some(self.budgets.finish(charge, outcome.usage)?);
                Collected::Attempt(
                    Operation {
                        intent: operation.intent,
                        phase,
                    },
                    outcome,
                )
            }
            (Flight::Backoff(operation), Completion::Backoff(result)) => {
                Collected::Backoff(operation.retired(), result)
            }
            (Flight::Observing(operation), Completion::Observed(result)) => {
                let (correlation, phase) = operation.phase.retire();
                reverse.cancel(&correlation, &host.request_scope()?);
                Collected::Observed(
                    Operation {
                        intent: operation.intent,
                        phase,
                    },
                    result,
                )
            }
            _ => return Err(CoreError::CleanupFailed),
        };
        if let Some(error) =
            self.retry_revoked(host, &mut pending, deadline, collected.retry_reference())
        {
            return self.finish(host, id, pending, Err(error));
        }
        match collected {
            Collected::Single(outcome) => self.finish(host, id, pending, outcome.result),
            Collected::Attempt(operation, outcome) => {
                self.retry_attempt_retired(host, id, pending, operation, outcome)
            }
            Collected::Backoff(operation, result) => {
                self.retry_backoff_retired(host, reverse, id, pending, operation, result)
            }
            Collected::Observed(operation, result) => match result {
                Ok(true) => self.retry_grant(host, id, pending, operation.accepted()),
                Ok(false) => self.finish(host, id, pending, Err(ApiError::Cancelled)),
                Err(error) => self.finish(host, id, pending, Err(error)),
            },
        }
    }

    fn retry_revoked(
        &mut self,
        host: &Host,
        pending: &mut Pending,
        deadline: Option<Deadline>,
        reference: Option<&budget::BudgetRef>,
    ) -> Option<ApiError> {
        if let Some(error) = pending.terminal.take() {
            return Some(error);
        }
        if pending.cancel.is_cancelled() || !host.owns_read_scope(&pending.scope) {
            return Some(ApiError::Cancelled);
        }
        if deadline.is_some_and(Deadline::expired) {
            // Expiry must be projected even when there is no ticket to finish.
            if let Some(reference) = reference {
                let _ = self.retry_preflight(host, pending, reference);
            }
            return Some(ApiError::RunDeadline);
        }
        None
    }

    fn retry_attempt_retired(
        &mut self,
        host: &Host,
        id: RpcId,
        pending: Pending,
        operation: Operation<exchange::Retired>,
        outcome: super::Outcome,
    ) -> Result<Option<Value>, CoreError> {
        let Err(error) = outcome.result else {
            return self.finish(host, id, pending, outcome.result);
        };
        if !operation.intent.configuration.policy.retryable(&error) {
            return self.finish(host, id, pending, Err(error));
        }
        let decision = operation
            .intent
            .configuration
            .policy
            .after_failure_observed(
                operation.intent.attempt,
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
            Ok(RetryDecision::Wait(delay)) => self.retry_wait(host, id, pending, operation, delay),
            Ok(RetryDecision::Stop(_)) => self.finish(host, id, pending, Err(error)),
            Err(_) => self.finish(host, id, pending, Err(ApiError::RetryUnavailable)),
        }
    }

    fn retry_wait(
        &mut self,
        host: &Host,
        id: RpcId,
        mut pending: Pending,
        operation: Operation<exchange::Retired>,
        delay: crate::api::resilience::RetryDelay,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = self.retry_preflight(host, &mut pending, &operation.intent.reference) {
            return self.finish(host, id, pending, Err(error));
        }
        let operation = operation.wait();
        let deadline = operation.intent.deadline;
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
        self.pending.insert(
            id,
            Active {
                pending,
                flight: Flight::Backoff(operation),
            },
        );
        Ok(None)
    }

    fn retry_backoff_retired(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        mut pending: Pending,
        operation: Operation<exchange::ObserverReady>,
        result: Result<(), ApiError>,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = result {
            return self.finish(host, id, pending, Err(error));
        }
        if let Err(error) = self.retry_preflight(host, &mut pending, &operation.intent.reference) {
            return self.finish(host, id, pending, Err(error));
        }
        match operation.intent.configuration.observer {
            Observer::None => self.retry_grant(host, id, pending, operation.headless()),
            Observer::Editor => self.retry_observe(host, reverse, id, pending, operation),
        }
    }

    fn retry_preflight(
        &mut self,
        host: &Host,
        pending: &mut Pending,
        reference: &budget::BudgetRef,
    ) -> Result<(), ApiError> {
        let result = self.budgets.preflight(host, &pending.scope, reference);
        pending.snapshot = self.budgets.snapshot(&reference.budget_id);
        result.map_err(admission_failure)
    }

    fn retry_grant(
        &mut self,
        host: &Host,
        id: RpcId,
        mut pending: Pending,
        mut operation: Operation<exchange::ReplayReady>,
    ) -> Result<Option<Value>, CoreError> {
        if let Err(error) = self.retry_preflight(host, &mut pending, &operation.intent.reference) {
            return self.finish(host, id, pending, Err(error));
        }
        let attempt = operation.intent.attempt.next()?;
        let charge =
            match self
                .budgets
                .admit_metered(host, &pending.scope, &operation.intent.reference)
            {
                Ok(charge) => charge,
                Err(error) => return self.finish(host, id, pending, Err(admission_failure(error))),
            };
        operation.intent.attempt = attempt;
        let operation = operation.admitted(charge);
        self.workers.spawn(
            worker::Attempt {
                id: id.clone(),
                arguments: operation.intent.arguments.clone(),
                sender: self.sender.clone(),
                cancel: pending.cancel.clone(),
                deadline: Some(operation.intent.deadline),
                page_bytes: operation.intent.page_bytes,
                observe_entropy: true,
                expectation: if operation.intent.configuration.circuit.is_some() {
                    worker::ResponseExpectation::Model
                } else {
                    worker::ResponseExpectation::Raw
                },
            }
            .run(),
        );
        self.pending.insert(
            id,
            Active {
                pending,
                flight: Flight::Attempt(operation),
            },
        );
        Ok(None)
    }

    fn retry_observe(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        id: RpcId,
        pending: Pending,
        operation: Operation<exchange::ObserverReady>,
    ) -> Result<Option<Value>, CoreError> {
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
                "attempt":operation.intent.attempt.next()?,"budget":pending.snapshot}});
        if message.to_string().len().saturating_add(1) > host.frame_limit().as_usize() {
            return self.finish(host, id, pending, Err(ApiError::RetryUnavailable));
        }
        let deadline = operation.intent.deadline.cap(
            Instant::now()
                .checked_add(Duration::from_secs(10))
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let receiver = match reverse.register(correlation.clone(), host.request_scope()?, deadline)
        {
            Ok(receiver) => receiver,
            Err(_) => return self.finish(host, id, pending, Err(ApiError::RetryUnavailable)),
        };
        let operation = operation.observe(correlation);
        let budget_deadline = operation.intent.deadline;
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
        self.pending.insert(
            id,
            Active {
                pending,
                flight: Flight::Observing(operation),
            },
        );
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
        let object = payload.as_object_mut().ok_or(CoreError::CleanupFailed)?;
        if let Some(snapshot) = pending.snapshot {
            object.insert("budget".to_owned(), snapshot);
        }
        if let Some(circuit) = circuit {
            object.insert("circuit".to_owned(), circuit);
        }
        self.circuits.collect(host);
        Ok(Some(protocol::success(&id, payload)))
    }
}
