//! Captured intent -> admitted logical operation. No IO starts in this module.

use super::{
    ApiError, ApiRequests, Fault, HttpRequest, Request, budget, circuit, fault, flight::Flight,
    retry,
};
use crate::{
    api::resilience::exchange,
    application::{
        budget::DebitKind,
        host::{Host, ReadScope},
    },
    constants::limits,
    domain::{ApiPageBytes, RetryAttempt},
};
use std::sync::Arc;

struct Captured {
    scope: ReadScope,
    arguments: Arc<HttpRequest>,
    mode: Mode,
}
enum Mode {
    Single(Option<budget::BudgetRef>),
    Retry {
        configuration: retry::Configuration,
        reference: budget::BudgetRef,
    },
}
impl TryFrom<Request> for Captured {
    type Error = ApiError;
    fn try_from(request: Request) -> Result<Self, ApiError> {
        let mode = match (request.retry, request.budget) {
            (None, budget) => Mode::Single(budget),
            (Some(configuration), Some(reference)) if request.arguments.generative() => {
                Mode::Retry {
                    configuration,
                    reference,
                }
            }
            _ => return Err(ApiError::InvalidRequest),
        };
        Ok(Self {
            scope: request.scope,
            arguments: Arc::new(request.arguments),
            mode,
        })
    }
}
#[must_use = "Admitted charges and leases must be retained until worker collection"]
pub(super) struct Admitted {
    pub scope: ReadScope,
    pub arguments: Arc<HttpRequest>,
    pub flight: Flight,
    pub circuit: Option<circuit::Grant>,
    pub page_bytes: ApiPageBytes,
}
impl ApiRequests {
    pub(super) fn admit_request(
        &mut self,
        host: &Host,
        request: Request,
    ) -> Result<Admitted, Fault> {
        if !host.owns_read_scope(&request.scope) {
            return Err(fault("stale_owner", "API owner is no longer live"));
        }
        if self.root.is_cancelled() || self.pending.len() >= limits::API_REQUESTS {
            return Err(fault("resource_limit", "API admission limit reached"));
        }
        let page_bytes = ApiPageBytes::try_from(host.frame_limit())
            .map_err(|_| fault("resource_limit", "API framing capacity unavailable"))?;
        self.admit_capture(
            host,
            Captured::try_from(request).map_err(|_| Fault::params())?,
            page_bytes,
        )
    }
    fn admit_capture(
        &mut self,
        host: &Host,
        capture: Captured,
        page_bytes: ApiPageBytes,
    ) -> Result<Admitted, Fault> {
        let circuit = self.capture_circuit(host, &capture)?;
        let flight = match self.capture_flight(
            host,
            &capture.scope,
            &capture.arguments,
            capture.mode,
            page_bytes,
        ) {
            Ok(admitted) => admitted,
            Err(error) => {
                if let Some(grant) = circuit {
                    self.circuits
                        .finish(grant, None)
                        .map_err(|_| fault("resource_limit", "Circuit cleanup failed"))?;
                }
                return Err(error.into());
            }
        };
        Ok(Admitted {
            scope: capture.scope,
            arguments: capture.arguments,
            flight,
            circuit,
            page_bytes,
        })
    }
    fn capture_circuit(
        &mut self,
        host: &Host,
        capture: &Captured,
    ) -> Result<Option<circuit::Grant>, Fault> {
        let Mode::Retry { configuration, .. } = &capture.mode else {
            return Ok(None);
        };
        match configuration.circuit {
            Some(policy) => self
                .circuits
                .acquire(
                    host,
                    &capture.scope,
                    &capture.arguments,
                    policy,
                    &configuration.policy,
                )
                .map(Some),
            None => Ok(None),
        }
    }
    fn capture_flight(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        arguments: &Arc<HttpRequest>,
        mode: Mode,
        page_bytes: ApiPageBytes,
    ) -> Result<Flight, budget::AdmissionFailure> {
        let (configuration, reference) = match mode {
            Mode::Retry {
                configuration,
                reference,
            } => (configuration, reference),
            Mode::Single(budget) => {
                return self
                    .budgets
                    .admit(host, scope, budget.as_ref(), arguments.generative())
                    .map(Flight::Single);
            }
        };
        let charge = self.budgets.admit_metered(host, scope, &reference)?;
        let intent = retry::Intent {
            configuration,
            arguments: arguments.clone(),
            reference: budget::BudgetRef {
                budget_id: reference.budget_id,
                kind: DebitKind::RetryAttempt,
            },
            deadline: charge.deadline,
            attempt: RetryAttempt::ZERO,
            page_bytes,
        };
        Ok(Flight::Attempt(retry::Operation {
            intent,
            phase: exchange::Attempt::charged(charge),
        }))
    }
}
