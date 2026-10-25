//! Retry/circuit domain proofs before mailbox/consumer cutover.

use kargu_core::{
    api::{
        ApiError,
        resilience::{
            Circuit, CircuitOutcome, CircuitPhase, CircuitPolicy, CircuitRefusal, RetryPolicy,
        },
    },
    domain::RetryAttempt,
};
use serde_json::{Value, json};
use std::time::{Duration, SystemTime};
use tokio::time::Instant;
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn circuit() -> Result<Circuit, serde_json::Error> {
    Ok(Circuit::new(serde_json::from_value(
        json!({"failure_threshold":1,"cooldown_ms":10}),
    )?))
}
fn later(at: Instant) -> Result<Instant, Box<dyn std::error::Error>> {
    at.checked_add(Duration::from_millis(10))
        .ok_or_else(|| "time overflow".into())
}

#[test]
fn policies_reject_invalid_units_statuses_duplicates_and_relations() -> TestResult {
    for value in [
        json!({"retry_max":11}),
        json!({"retry_max":-1}),
        json!({"retry_max":1.5}),
        json!({"backoff_base_ms":0}),
        json!({"backoff_cap_ms":60001}),
        json!({"retry_after_max_ms":86400001}),
        json!({"backoff_base_ms":20,"backoff_cap_ms":10}),
        json!({"statuses":[503,503]}),
        json!({"statuses":[401]}),
        json!({"statuses":[403]}),
        json!({"statuses":[400]}),
        json!({"other":1}),
    ] {
        assert!(serde_json::from_value::<RetryPolicy>(value).is_err());
    }
    for value in [
        json!({"failure_threshold":0}),
        json!({"failure_threshold":1001}),
        json!({"cooldown_ms":0}),
        json!({"cooldown_ms":86400001}),
        json!({"other":1}),
    ] {
        assert!(serde_json::from_value::<CircuitPolicy>(value).is_err());
    }
    let disabled: RetryPolicy =
        serde_json::from_value(json!({"retry_max":0,"statuses":[],"retry_after_max_ms":0}))?;
    assert!(!disabled.retryable(&ApiError::Http {
        status: reqwest::StatusCode::SERVICE_UNAVAILABLE,
        retry_after: None
    }));
    Ok(())
}

#[test]
fn typed_upstream_allowlist_never_guesses_from_owner_or_transport_text() -> TestResult {
    let policy: RetryPolicy = serde_json::from_value(json!({}))?;
    for status in [429, 500, 502, 503, 504, 529] {
        let error = ApiError::Http {
            status: reqwest::StatusCode::from_u16(status)?,
            retry_after: None,
        };
        assert!(policy.retryable(&error));
        assert!(policy.upstream_failure(&error));
    }
    for error in [
        ApiError::Cancelled,
        ApiError::RunDeadline,
        ApiError::Connection,
        ApiError::InvalidRequest,
        ApiError::Limit,
        ApiError::Protocol,
        ApiError::Incomplete,
        ApiError::Redirect,
        ApiError::Http {
            status: reqwest::StatusCode::UNAUTHORIZED,
            retry_after: None,
        },
        ApiError::ContextOverflow {
            status: reqwest::StatusCode::BAD_REQUEST,
        },
    ] {
        assert!(!policy.retryable(&error));
        assert!(!policy.upstream_failure(&error));
    }
    for error in [
        ApiError::FirstByteTimeout,
        ApiError::IdleTimeout,
        ApiError::Deadline,
    ] {
        assert!(!policy.retryable(&error));
        assert!(policy.upstream_failure(&error));
    }
    let zero: RetryPolicy = serde_json::from_value(json!({"retry_max":0}))?;
    assert!(matches!(
        zero.after_failure(
            RetryAttempt::ZERO,
            &ApiError::Http {
                status: reqwest::StatusCode::SERVICE_UNAVAILABLE,
                retry_after: None
            },
            kargu_core::api::resilience::Publication::Silent,
            SystemTime::now()
        )?,
        kargu_core::api::resilience::RetryDecision::Stop(_)
    ));
    Ok(())
}

#[test]
fn open_circuit_admits_only_one_half_open_probe_after_original_cooldown() -> TestResult {
    let mut circuit = circuit()?;
    let now = Instant::now();
    let lease = circuit.acquire(now)?;
    circuit.record(lease, CircuitOutcome::UpstreamFailure, now)?;
    assert_eq!(circuit.phase(), CircuitPhase::Open);
    assert!(matches!(circuit.acquire(now), Err(CircuitRefusal::Cooling)));
    let at = later(now)?;
    let probe = circuit.acquire(at)?;
    assert_eq!(circuit.phase(), CircuitPhase::HalfOpen);
    assert!(matches!(
        circuit.acquire(at),
        Err(CircuitRefusal::ProbeBusy)
    ));
    circuit.record(probe, CircuitOutcome::Success, at)?;
    assert_eq!(circuit.phase(), CircuitPhase::Closed);
    assert_eq!(circuit.failures().as_u64(), 0);
    Ok(())
}

#[test]
fn local_rejection_and_probe_cancel_do_not_declare_service_healthy_or_failed() -> TestResult {
    let mut circuit = circuit()?;
    let now = Instant::now();
    let lease = circuit.acquire(now)?;
    circuit.record(lease, CircuitOutcome::Neutral, now)?;
    assert_eq!(circuit.failures().as_u64(), 0);
    let lease = circuit.acquire(now)?;
    circuit.record(lease, CircuitOutcome::UpstreamFailure, now)?;
    let at = later(now)?;
    let probe = circuit.acquire(at)?;
    circuit.record(probe, CircuitOutcome::Neutral, at)?;
    assert_eq!(circuit.phase(), CircuitPhase::HalfOpen);
    assert_eq!(circuit.failures().as_u64(), 1);
    let probe = circuit.acquire(at)?;
    circuit.record(probe, CircuitOutcome::UpstreamFailure, at)?;
    assert_eq!(circuit.phase(), CircuitPhase::Open);
    assert_eq!(circuit.failures().as_u64(), 2);
    assert!(matches!(circuit.acquire(at), Err(CircuitRefusal::Cooling)));
    Ok(())
}

#[test]
fn pre_open_and_pre_reset_late_completions_cannot_mutate_new_circuit_state() -> TestResult {
    let mut circuit = circuit()?;
    let now = Instant::now();
    let late = circuit.acquire(now)?;
    let failure = circuit.acquire(now)?;
    circuit.record(failure, CircuitOutcome::UpstreamFailure, now)?;
    circuit.record(late, CircuitOutcome::Success, now)?;
    assert_eq!(circuit.phase(), CircuitPhase::Open);
    assert_eq!(circuit.failures().as_u64(), 1);
    let probe = circuit.acquire(later(now)?)?;
    circuit.reset()?;
    circuit.record(probe, CircuitOutcome::UpstreamFailure, later(now)?)?;
    assert_eq!(circuit.phase(), CircuitPhase::Closed);
    assert_eq!(circuit.failures().as_u64(), 0);
    Ok(())
}

#[test]
fn foreign_regular_lease_cannot_charge_another_circuit_at_same_revision() -> TestResult {
    let mut first = circuit()?;
    let mut second = circuit()?;
    let now = Instant::now();
    let lease = first.acquire(now)?;
    assert!(
        second
            .record(lease, CircuitOutcome::UpstreamFailure, now)
            .is_err()
    );
    assert_eq!(second.failures().as_u64(), 0);
    assert_eq!(second.phase(), CircuitPhase::Closed);
    Ok(())
}

#[test]
fn only_consecutive_upstream_failures_trip_and_policy_is_captured() -> TestResult {
    let raw: Value = json!({"failure_threshold":2,"cooldown_ms":10});
    let mut circuit = Circuit::new(serde_json::from_value(raw)?);
    let now = Instant::now();
    let first = circuit.acquire(now)?;
    circuit.record(first, CircuitOutcome::UpstreamFailure, now)?;
    assert_eq!(circuit.phase(), CircuitPhase::Closed);
    assert_eq!(circuit.failures().as_u64(), 1);
    let healthy = circuit.acquire(now)?;
    circuit.record(healthy, CircuitOutcome::Success, now)?;
    assert_eq!(circuit.failures().as_u64(), 0);
    for _ in 0..2 {
        let lease = circuit.acquire(now)?;
        circuit.record(lease, CircuitOutcome::UpstreamFailure, now)?;
    }
    assert_eq!(circuit.phase(), CircuitPhase::Open);
    Ok(())
}
