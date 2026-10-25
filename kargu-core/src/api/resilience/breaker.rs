//! Single-probe state machine. Reset/reopen invalidate older completion rights.

use super::CircuitPolicy;
use crate::{
    domain::{CircuitId, CircuitRevision, ProbeId, UpstreamFailures},
    error::CoreError,
};
use tokio::time::Instant;

enum State {
    Closed,
    Open { retry_at: Instant },
    ProbeReady,
    Probing { id: ProbeId },
}
enum Lease {
    Regular,
    Probe(ProbeId),
}
/// Move-only outcome right; not deserializable or an external execution grant.
#[must_use = "Record success, classified failure or neutral cancellation for each lease"]
pub struct CircuitLease {
    owner: CircuitId,
    revision: CircuitRevision,
    kind: Lease,
}
/// Display phase; a half-open circuit may have an available or occupied probe.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CircuitPhase {
    /// Normal admission.
    Closed,
    /// Cooldown prevents admission.
    Open,
    /// Only one probe may be in flight.
    HalfOpen,
}
/// Actor-classified terminal observation; no upstream text is accepted.
#[derive(Clone, Copy, Debug)]
pub enum CircuitOutcome {
    /// A complete, valid terminal result.
    Success,
    /// Allowlisted upstream failure.
    UpstreamFailure,
    /// Owner revocation, policy refusal, client/TLS or unknown transport fault.
    Neutral,
}
/// Non-mutating admission refusal; neither kind charges an HTTP budget.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CircuitRefusal {
    /// Original cooldown has not elapsed.
    #[error("upstream circuit cooling down")]
    Cooling,
    /// The sole half-open probe is already owned.
    #[error("upstream probe already in flight")]
    ProbeBusy,
}
/// Pure single-writer circuit; the owning actor scopes and bounds its registry.
pub struct Circuit {
    id: CircuitId,
    policy: CircuitPolicy,
    state: State,
    failures: UpstreamFailures,
    revision: CircuitRevision,
}
/// Detached UI projection. Neither a probe nor an execution capability.
#[derive(serde::Serialize)]
pub struct CircuitSnapshot {
    circuit_id: CircuitId,
    state: CircuitPhase,
    failures: UpstreamFailures,
    cooldown_remaining_ms: u64,
    probe_inflight: bool,
}
impl Circuit {
    /// Opaque registry identity, never an upstream/auth fingerprint.
    pub fn id(&self) -> &CircuitId {
        &self.id
    }
    /// Display elapsed cooldown without acquiring/mutating the sole probe.
    pub fn snapshot(&self, now: Instant) -> Result<CircuitSnapshot, CoreError> {
        let (state, remaining) = match self.state {
            State::Open { retry_at } if retry_at > now => {
                (CircuitPhase::Open, retry_at.duration_since(now))
            }
            State::Open { .. } => (CircuitPhase::HalfOpen, std::time::Duration::ZERO),
            _ => (self.phase(), std::time::Duration::ZERO),
        };
        Ok(CircuitSnapshot {
            circuit_id: self.id.clone(),
            state,
            failures: self.failures,
            cooldown_remaining_ms: u64::try_from(remaining.as_millis())
                .map_err(|_| CoreError::ArithmeticOverflow)?,
            probe_inflight: matches!(self.state, State::Probing { .. }),
        })
    }
    /// Capture one immutable policy; no global mutable default is consulted later.
    pub fn new(policy: CircuitPolicy) -> Self {
        Self {
            id: CircuitId::new(),
            policy,
            state: State::Closed,
            failures: UpstreamFailures::ZERO,
            revision: CircuitRevision::ZERO,
        }
    }
    /// Reserve normal or sole-probe completion rights before budget/IO admission.
    pub fn acquire(&mut self, now: Instant) -> Result<CircuitLease, CircuitRefusal> {
        let kind = match &self.state {
            State::Closed => Lease::Regular,
            State::Open { retry_at } if now < *retry_at => return Err(CircuitRefusal::Cooling),
            State::Probing { .. } => return Err(CircuitRefusal::ProbeBusy),
            State::Open { .. } | State::ProbeReady => {
                let id = ProbeId::new();
                self.state = State::Probing { id: id.clone() };
                Lease::Probe(id)
            }
        };
        Ok(CircuitLease {
            owner: self.id.clone(),
            revision: self.revision,
            kind,
        })
    }
    /// Consume an outcome right once. Late pre-reset/pre-open results are inert.
    pub fn record(
        &mut self,
        lease: CircuitLease,
        outcome: CircuitOutcome,
        now: Instant,
    ) -> Result<(), CoreError> {
        if lease.owner != self.id {
            return Err(CoreError::StaleOwner);
        }
        if lease.revision != self.revision {
            return Ok(());
        }
        match lease.kind {
            Lease::Regular if matches!(self.state, State::Closed) => match outcome {
                CircuitOutcome::Success => self.failures = UpstreamFailures::ZERO,
                CircuitOutcome::Neutral => {}
                CircuitOutcome::UpstreamFailure => {
                    let failures = self.failures.next()?;
                    if failures.as_u64() >= self.policy.threshold() {
                        self.trip(failures, now)?;
                    } else {
                        self.failures = failures;
                    }
                }
            },
            Lease::Probe(id) if matches!(&self.state,State::Probing { id:owner } if owner==&id) => {
                match outcome {
                    CircuitOutcome::Success => {
                        let revision = self.revision.next()?;
                        self.state = State::Closed;
                        self.failures = UpstreamFailures::ZERO;
                        self.revision = revision;
                    }
                    CircuitOutcome::Neutral => self.state = State::ProbeReady,
                    CircuitOutcome::UpstreamFailure => self.trip(self.failures.next()?, now)?,
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn trip(&mut self, failures: UpstreamFailures, now: Instant) -> Result<(), CoreError> {
        let retry_at = now
            .checked_add(self.policy.cooldown())
            .ok_or(CoreError::ArithmeticOverflow)?;
        let revision = self.revision.next()?;
        self.state = State::Open { retry_at };
        self.failures = failures;
        self.revision = revision;
        Ok(())
    }
    /// Explicit reset invalidates old success/failure rights without replaying IO.
    pub fn reset(&mut self) -> Result<(), CoreError> {
        let revision = self.revision.next()?;
        self.state = State::Closed;
        self.failures = UpstreamFailures::ZERO;
        self.revision = revision;
        Ok(())
    }
    /// Read phase without acquiring the sole probe or changing a cooldown.
    pub fn phase(&self) -> CircuitPhase {
        match self.state {
            State::Closed => CircuitPhase::Closed,
            State::Open { .. } => CircuitPhase::Open,
            State::ProbeReady | State::Probing { .. } => CircuitPhase::HalfOpen,
        }
    }
    /// Detached consecutive-failure counter; never an admission capability.
    pub fn failures(&self) -> UpstreamFailures {
        self.failures
    }
}
