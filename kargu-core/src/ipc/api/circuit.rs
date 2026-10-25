//! Bounded application/upstream registry. A lease spans the entire logical retry.

use super::{Fault, HttpRequest, fault};
use crate::{
    api::{
        ApiAuthority, ApiError,
        resilience::{
            Circuit, CircuitLease, CircuitOutcome, CircuitPhase, CircuitPolicy, RetryPolicy,
        },
    },
    application::host::{Host, ReadScope},
    constants::{limits, protocol::methods},
    domain::{ApplicationId, CircuitId, CircuitProjectionSequence},
    error::CoreError,
    providers::ApiProviderId,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio::time::Instant;

#[derive(Default)]
struct ActiveClaims(usize);
impl ActiveClaims {
    fn next(&self) -> Result<Self, CoreError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(CoreError::ArithmeticOverflow)
    }
    fn previous(&self) -> Result<Self, CoreError> {
        self.0
            .checked_sub(1)
            .map(Self)
            .ok_or(CoreError::CleanupFailed)
    }
    fn drained(&self) -> bool {
        self.0 == 0
    }
}
struct Owned {
    owner: ApplicationId,
    authority: ApiAuthority,
    provider: Option<ApiProviderId>,
    policy: CircuitPolicy,
    classification: RetryPolicy,
    circuit: Circuit,
    active: ActiveClaims,
}
/// Move-only completion right, retained independently of each physical charge.
#[must_use = "Release only after all attempts/backoff/observer resources have joined"]
pub(super) struct Grant {
    id: CircuitId,
    lease: CircuitLease,
}
#[derive(Default)]
pub(super) struct Circuits {
    entries: HashMap<CircuitId, Owned>,
    sequence: CircuitProjectionSequence,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    scope: ReadScope,
    #[serde(default)]
    circuit_id: Option<CircuitId>,
    #[serde(default)]
    provider: Option<ApiProviderId>,
}
impl Circuits {
    pub fn owns_application(&self, id: &ApplicationId) -> bool {
        self.entries.values().any(|entry| &entry.owner == id)
    }
    pub fn collect(&mut self, host: &Host) {
        self.entries
            .retain(|_, entry| host.owns_application(&entry.owner) || !entry.active.drained());
    }
    fn evict_healthy(&mut self) {
        if self.entries.len() < limits::API_CIRCUITS {
            return;
        }
        let idle = self
            .entries
            .iter()
            .find(|(_, entry)| {
                entry.active.drained()
                    && entry.circuit.phase() == CircuitPhase::Closed
                    && entry.circuit.failures().as_u64() == 0
            })
            .map(|(id, _)| id.clone());
        if let Some(id) = idle {
            self.entries.remove(&id);
        }
    }
    pub fn acquire(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        request: &HttpRequest,
        policy: CircuitPolicy,
        classification: &RetryPolicy,
    ) -> Result<Grant, Fault> {
        if !host.owns_read_scope(scope) {
            return Err(stale());
        }
        self.collect(host);
        let existing = self
            .entries
            .iter()
            .find(|(_, entry)| {
                entry.owner == scope.application_id
                    && entry.authority == request.authority
                    && entry.policy == policy
                    && &entry.classification == classification
            })
            .map(|(id, _)| id.clone());
        let id = match existing {
            Some(id) => id,
            None => self.create(scope, request, policy, classification)?,
        };
        let entry = self.entries.get_mut(&id).ok_or_else(stale)?;
        let active = entry.active.next().map_err(|_| exhausted())?;
        let lease = entry.circuit.acquire(Instant::now()).map_err(|_| {
            fault(
                "circuit_open",
                "Upstream circuit cooling down or probe occupied",
            )
        })?;
        entry.active = active;
        Ok(Grant { id, lease })
    }
    fn create(
        &mut self,
        scope: &ReadScope,
        request: &HttpRequest,
        policy: CircuitPolicy,
        classification: &RetryPolicy,
    ) -> Result<CircuitId, Fault> {
        self.evict_healthy();
        if self.entries.len() >= limits::API_CIRCUITS {
            return Err(exhausted());
        }
        let circuit = Circuit::new(policy);
        let id = circuit.id().clone();
        self.entries.insert(
            id.clone(),
            Owned {
                owner: scope.application_id.clone(),
                authority: request.authority.clone(),
                provider: request.provider.clone(),
                policy,
                classification: classification.clone(),
                circuit,
                active: ActiveClaims::default(),
            },
        );
        Ok(id)
    }
    pub fn finish(
        &mut self,
        grant: Grant,
        result: Option<&Result<Value, ApiError>>,
    ) -> Result<Value, CoreError> {
        let entry = self
            .entries
            .get_mut(&grant.id)
            .ok_or(CoreError::CleanupFailed)?;
        let active = entry.active.previous()?;
        let outcome = match result {
            Some(Ok(_)) => CircuitOutcome::Success,
            Some(Err(error)) if entry.classification.upstream_failure(error) => {
                CircuitOutcome::UpstreamFailure
            }
            _ => CircuitOutcome::Neutral,
        };
        entry.active = active;
        entry.circuit.record(grant.lease, outcome, Instant::now())?;
        self.projection(&grant.id)
    }
    pub fn rpc(&mut self, host: &Host, method: &str, params: Value) -> Result<Value, Fault> {
        let request: Request = serde_json::from_value(params).map_err(|_| Fault::params())?;
        if request.circuit_id.is_some() && request.provider.is_some() {
            return Err(Fault::params());
        }
        if !host.owns_read_scope(&request.scope) {
            return Err(stale());
        }
        self.collect(host);
        let ids = self.selected(&request)?;
        let mut snapshots = Vec::with_capacity(ids.len());
        for id in ids {
            let entry = self.entries.get_mut(&id).ok_or_else(stale)?;
            if method == methods::API_CIRCUIT_RESET {
                entry.circuit.reset().map_err(|_| exhausted())?;
            }
            snapshots.push(self.projection(&id).map_err(|_| exhausted())?);
        }
        Ok(json!({"circuits":snapshots}))
    }
    fn projection(&mut self, id: &CircuitId) -> Result<Value, CoreError> {
        let sequence = self.sequence.next()?;
        let entry = self.entries.get(id).ok_or(CoreError::CleanupFailed)?;
        let mut snapshot = json!(entry.circuit.snapshot(Instant::now())?);
        snapshot["provider"] = json!(entry.provider.as_ref().map(ApiProviderId::as_str));
        snapshot["sequence"] = json!(sequence);
        self.sequence = sequence;
        Ok(snapshot)
    }
    fn selected(&self, request: &Request) -> Result<Vec<CircuitId>, Fault> {
        if let Some(id) = &request.circuit_id {
            return match self.entries.get(id) {
                Some(entry) if entry.owner == request.scope.application_id => Ok(vec![id.clone()]),
                _ => Err(stale()),
            };
        }
        Ok(self
            .entries
            .iter()
            .filter(|(_, entry)| {
                entry.owner == request.scope.application_id
                    && request
                        .provider
                        .as_ref()
                        .is_none_or(|provider| entry.provider.as_ref() == Some(provider))
            })
            .map(|(id, _)| id.clone())
            .collect())
    }
}
fn stale() -> Fault {
    fault(
        "stale_owner",
        "Circuit belongs to another or closed application",
    )
}
fn exhausted() -> Fault {
    fault("resource_limit", "Captured circuit resource limit reached")
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn context() -> Result<(Host, ReadScope), Box<dyn std::error::Error>> {
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"circuit-test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result?;
        host.dispatch("initialized", json!({}), false).result?;
        let application = host
            .dispatch("application/create", json!({}), true)
            .result?;
        let scope = host.dispatch("session/create", application, true).result?;
        Ok((host, serde_json::from_value(scope)?))
    }
    fn request(tenant: usize) -> Result<HttpRequest, serde_json::Error> {
        serde_json::from_value(
            json!({"method":"post","url":"https://fixture.invalid/chat","provider":"fixture",
            "headers":{"Authorization":format!("Bearer synthetic-{tenant}")},"stream":false,"body":"{}",
            "timeouts":{"connect_ms":500,"first_byte_ms":500,"idle_ms":null,"deadline_ms":1000}}),
        )
    }
    #[test]
    fn full_registry_does_not_evict_unhealthy_or_active_circuits_to_bypass_refusal() -> TestResult {
        let (host, scope) = context()?;
        let policy: CircuitPolicy =
            serde_json::from_value(json!({"failure_threshold":1,"cooldown_ms":30000}))?;
        let classification: RetryPolicy = serde_json::from_value(json!({}))?;
        let mut circuits = Circuits::default();
        let mut first = None;
        let failure = Err(ApiError::Http {
            status: reqwest::StatusCode::SERVICE_UNAVAILABLE,
            retry_after: None,
        });
        for tenant in 0..limits::API_CIRCUITS {
            let grant =
                circuits.acquire(&host, &scope, &request(tenant)?, policy, &classification)?;
            if first.is_none() {
                first = Some(grant.id.clone());
            }
            circuits.finish(grant, Some(&failure))?;
        }
        let next = request(limits::API_CIRCUITS)?;
        assert!(matches!(
            circuits.acquire(&host, &scope, &next, policy, &classification),
            Err(Fault {
                status: "resource_limit",
                ..
            })
        ));
        let first = first.ok_or("first circuit")?;
        circuits
            .entries
            .get_mut(&first)
            .ok_or("entry")?
            .circuit
            .reset()?;
        let held = circuits.acquire(&host, &scope, &request(0)?, policy, &classification)?;
        assert!(matches!(
            circuits.acquire(&host, &scope, &next, policy, &classification),
            Err(Fault {
                status: "resource_limit",
                ..
            })
        ));
        circuits.finish(held, None)?;
        let admitted = circuits.acquire(&host, &scope, &next, policy, &classification)?;
        assert!(!circuits.entries.contains_key(&first));
        assert_eq!(circuits.entries.len(), limits::API_CIRCUITS);
        circuits.finish(admitted, None)?;
        Ok(())
    }
    #[test]
    fn owner_close_retains_grant_until_collection_but_session_close_does_not_reset_application_health()
    -> TestResult {
        let (mut host, scope) = context()?;
        let mut circuits = Circuits::default();
        let classification: RetryPolicy = serde_json::from_value(json!({}))?;
        let grant = circuits.acquire(
            &host,
            &scope,
            &request(0)?,
            CircuitPolicy::default(),
            &classification,
        )?;
        host.dispatch(
            "session/close",
            json!({"application_id":scope.application_id,"session_id":scope.session_id}),
            true,
        )
        .result?;
        circuits.collect(&host);
        assert!(circuits.owns_application(&scope.application_id));
        host.close_application(json!({"application_id":scope.application_id}))?;
        circuits.collect(&host);
        assert!(circuits.owns_application(&scope.application_id));
        circuits.finish(grant, None)?;
        circuits.collect(&host);
        assert!(!circuits.owns_application(&scope.application_id));
        Ok(())
    }
}
