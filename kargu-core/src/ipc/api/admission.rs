//! Captured intent -> admitted logical operation. No IO starts in this module.

use super::{ApiRequests, Fault, HttpRequest, Request, budget, circuit, fault, retry};
use crate::{
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
    budget: Option<budget::BudgetRef>,
    retry: Option<retry::Configuration>,
    page_bytes: ApiPageBytes,
}
#[must_use = "Admitted charges and leases must be retained until worker collection"]
pub(super) struct Admitted {
    pub scope: ReadScope,
    pub arguments: Arc<HttpRequest>,
    pub charge: Option<budget::Charge>,
    pub retry: Option<retry::Operation>,
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
        if request.retry.is_some() && (request.budget.is_none() || !request.arguments.generative())
        {
            return Err(Fault::params());
        }
        let capture = Captured {
            scope: request.scope,
            arguments: Arc::new(request.arguments),
            budget: request.budget,
            retry: request.retry,
            page_bytes: ApiPageBytes::try_from(host.frame_limit())
                .map_err(|_| fault("resource_limit", "API framing capacity unavailable"))?,
        };
        self.admit_capture(host, capture)
    }
    fn admit_capture(&mut self, host: &Host, mut capture: Captured) -> Result<Admitted, Fault> {
        let circuit = self.capture_circuit(host, &capture)?;
        let (charge, retry) = match self.capture_charge(host, &mut capture) {
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
            charge,
            retry,
            circuit,
            page_bytes: capture.page_bytes,
        })
    }
    fn capture_circuit(
        &mut self,
        host: &Host,
        capture: &Captured,
    ) -> Result<Option<circuit::Grant>, Fault> {
        match capture
            .retry
            .as_ref()
            .and_then(|config| config.circuit.map(|policy| (policy, &config.policy)))
        {
            Some((policy, classification)) => self
                .circuits
                .acquire(
                    host,
                    &capture.scope,
                    &capture.arguments,
                    policy,
                    classification,
                )
                .map(Some),
            None => Ok(None),
        }
    }
    fn capture_charge(
        &mut self,
        host: &Host,
        capture: &mut Captured,
    ) -> Result<(Option<budget::Charge>, Option<retry::Operation>), budget::AdmissionFailure> {
        let Some(configuration) = capture.retry.take() else {
            return self
                .budgets
                .admit(
                    host,
                    &capture.scope,
                    capture.budget.as_ref(),
                    capture.arguments.generative(),
                )
                .map(|charge| (charge, None));
        };
        let reference = capture
            .budget
            .as_ref()
            .ok_or(budget::AdmissionFailure::Required)?;
        let charge = self
            .budgets
            .admit_metered(host, &capture.scope, reference)?;
        let operation = retry::Operation {
            configuration,
            arguments: capture.arguments.clone(),
            reference: budget::BudgetRef {
                budget_id: reference.budget_id.clone(),
                kind: DebitKind::RetryAttempt,
            },
            deadline: charge.deadline,
            attempt: RetryAttempt::ZERO,
            stage: Some(retry::Stage::Attempt),
            page_bytes: capture.page_bytes,
        };
        Ok((Some(charge), Some(operation)))
    }
}
