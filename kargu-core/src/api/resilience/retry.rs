//! Bounded full jitter and RFC 9110 Retry-After, never free-text classification.

use super::{
    Publication, RetryDelay,
    domain::{BackoffBase, BackoffCap, RetryDto, RetryLimit, RetryStatus, ServerWaitLimit},
};
use crate::{api::ApiError, constants::limits, domain::RetryAttempt, error::CoreError};
use serde::Deserialize;
use std::time::{Duration, SystemTime};

/// An explicit decision not to replay is distinct from a zero-duration retry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryStop {
    /// Failure is not in the captured transient status allowlist.
    NotRetryable,
    /// A model-visible response cannot be blindly replayed.
    Published,
    /// Captured physical retry count is spent.
    Attempts,
    /// Respect the server wait; do not clamp it into an earlier request.
    ServerWait,
}
/// Pure policy result; the actor separately checks owner, budget and breaker.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    /// Terminal, with a closed classification.
    Stop(RetryStop),
    /// Wait without releasing the logical operation's owned resource slot.
    Wait(RetryDelay),
}
/// Immutable policy captured before asynchronous admission.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Deserialize)]
#[serde(try_from = "RetryDto")]
pub struct RetryPolicy {
    maximum: RetryLimit,
    statuses: Vec<RetryStatus>,
    base: BackoffBase,
    cap: BackoffCap,
    server_limit: ServerWaitLimit,
}
impl TryFrom<RetryDto> for RetryPolicy {
    type Error = CoreError;
    fn try_from(value: RetryDto) -> Result<Self, CoreError> {
        if !value.consistent() {
            return Err(CoreError::InvalidValue {
                field: "RetryPolicy",
            });
        }
        Ok(Self {
            maximum: value.retry_max,
            statuses: value.statuses,
            base: value.backoff_base_ms,
            cap: value.backoff_cap_ms,
            server_limit: value.retry_after_max_ms,
        })
    }
}
impl RetryPolicy {
    /// Whether a classified HTTP failure may be retried; no body/URL matching.
    pub fn retryable(&self, error: &ApiError) -> bool {
        matches!(error, ApiError::Http { status, .. } if self.statuses.iter().any(|candidate| candidate.matches(*status)))
    }
    /// Decide with OS entropy. Failure to obtain it never becomes zero jitter.
    pub fn after_failure(
        &self,
        attempt: RetryAttempt,
        error: &ApiError,
        publication: Publication,
        now: SystemTime,
    ) -> Result<RetryDecision, CoreError> {
        self.decide_with(attempt, error, publication, now, || {
            getrandom::u64().map_err(|_| CoreError::Unavailable)
        })
    }
    fn decide_with(
        &self,
        attempt: RetryAttempt,
        error: &ApiError,
        publication: Publication,
        now: SystemTime,
        mut entropy: impl FnMut() -> Result<u64, CoreError>,
    ) -> Result<RetryDecision, CoreError> {
        if publication == Publication::Visible {
            return Ok(RetryDecision::Stop(RetryStop::Published));
        }
        if !self.retryable(error) {
            return Ok(RetryDecision::Stop(RetryStop::NotRetryable));
        }
        if attempt.as_u64() >= self.maximum.count() {
            return Ok(RetryDecision::Stop(RetryStop::Attempts));
        }
        let server = match error {
            ApiError::Http {
                retry_after: Some(raw),
                ..
            } => server_wait(raw, now, self.server_limit.duration()),
            _ => ServerWait::Absent,
        };
        let minimum = match server {
            ServerWait::TooLong => return Ok(RetryDecision::Stop(RetryStop::ServerWait)),
            ServerWait::Delay(delay) => delay,
            ServerWait::Absent => Duration::ZERO,
        };
        // RetryLimit bounds the exponent before this conversion. This method
        // nevertheless accepts arbitrary typed attempt counts and checks it.
        let exponent =
            u32::try_from(attempt.as_u64()).map_err(|_| CoreError::ArithmeticOverflow)?;
        let multiplier = 1u32
            .checked_shl(exponent)
            .ok_or(CoreError::ArithmeticOverflow)?;
        let upper = self
            .base
            .duration()
            .checked_mul(multiplier)
            .ok_or(CoreError::ArithmeticOverflow)?
            .min(self.cap.duration());
        let upper = u64::try_from(upper.as_nanos()).map_err(|_| CoreError::ArithmeticOverflow)?;
        let width = upper.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?;
        // Rejection sampling preserves equal probability for every nanosecond.
        // Excluding one extra tail bucket is harmless and avoids MAX + 1.
        let cutoff = u64::MAX
            .checked_sub(u64::MAX % width)
            .ok_or(CoreError::ArithmeticOverflow)?;
        for _ in 0..limits::API_RANDOM_DRAWS {
            let sample = entropy()?;
            if sample < cutoff {
                return Ok(RetryDecision::Wait(RetryDelay(
                    Duration::from_nanos(sample % width).max(minimum),
                )));
            }
        }
        Err(CoreError::Unavailable)
    }
    /// Only classified upstream faults count; owner/client/unknown TLS do not.
    pub fn upstream_failure(&self, error: &ApiError) -> bool {
        self.retryable(error)
            || matches!(
                error,
                ApiError::FirstByteTimeout | ApiError::IdleTimeout | ApiError::Deadline
            )
    }
}
enum ServerWait {
    Absent,
    Delay(Duration),
    TooLong,
}
fn server_wait(raw: &str, now: SystemTime, limit: Duration) -> ServerWait {
    let raw = raw.trim_matches([' ', '\t']);
    if raw.len() > 128 {
        return ServerWait::TooLong;
    }
    if raw.is_empty() {
        return ServerWait::Absent;
    }
    let delay = if raw.bytes().all(|byte| byte.is_ascii_digit()) {
        match raw.parse::<u64>() {
            Ok(seconds) => Duration::from_secs(seconds),
            Err(_) => return ServerWait::TooLong,
        }
    } else {
        match httpdate::parse_http_date(raw) {
            Ok(at) => at.duration_since(now).unwrap_or(Duration::ZERO),
            Err(_) => return ServerWait::Absent,
        }
    };
    if delay > limit {
        ServerWait::TooLong
    } else {
        ServerWait::Delay(delay)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn policy(extra: serde_json::Value) -> Result<RetryPolicy, serde_json::Error> {
        serde_json::from_value(extra)
    }
    fn upstream(header: Option<&str>) -> ApiError {
        ApiError::Http {
            status: reqwest::StatusCode::SERVICE_UNAVAILABLE,
            retry_after: header.map(str::to_owned),
        }
    }
    fn wait(value: RetryDecision) -> Result<Duration, Box<dyn std::error::Error>> {
        match value {
            RetryDecision::Wait(delay) => Ok(delay.duration()),
            _ => Err("expected wait".into()),
        }
    }
    #[test]
    fn full_jitter_includes_zero_and_upper_bound_without_a_half_second_floor() -> TestResult {
        let policy = policy(json!({}))?;
        let now = SystemTime::now();
        let first = RetryAttempt::ZERO;
        assert_eq!(
            wait(policy.decide_with(first, &upstream(None), Publication::Silent, now, || Ok(0))?)?,
            Duration::ZERO
        );
        assert_eq!(
            wait(
                policy.decide_with(first, &upstream(None), Publication::Silent, now, || Ok(
                    1_000_000_000
                ))?
            )?,
            Duration::from_secs(1)
        );
        assert_eq!(
            wait(policy.decide_with(
                RetryAttempt::try_from(4)?,
                &upstream(None),
                Publication::Silent,
                now,
                || Ok(16_000_000_000)
            )?)?,
            Duration::from_secs(16)
        );
        let capped = self::policy(json!({"retry_max":10}))?;
        assert_eq!(
            wait(capped.decide_with(
                RetryAttempt::try_from(9)?,
                &upstream(None),
                Publication::Silent,
                now,
                || Ok(32_000_000_000)
            )?)?,
            Duration::from_secs(32)
        );
        Ok(())
    }
    #[test]
    fn retry_after_seconds_and_http_date_are_minimums_not_clamped_early() -> TestResult {
        let policy = policy(json!({}))?;
        let now = SystemTime::UNIX_EPOCH
            .checked_add(Duration::from_secs(1_700_000_000))
            .ok_or("time")?;
        let date = httpdate::fmt_http_date(now.checked_add(Duration::from_secs(3)).ok_or("date")?);
        for raw in ["3", date.as_str()] {
            assert_eq!(
                wait(policy.decide_with(
                    RetryAttempt::ZERO,
                    &upstream(Some(raw)),
                    Publication::Silent,
                    now,
                    || Ok(0)
                )?)?,
                Duration::from_secs(3)
            );
        }
        let oversized = "9".repeat(129);
        for raw in ["61", "184467440737095516160000", oversized.as_str()] {
            let mut draws = 0;
            assert_eq!(
                policy.decide_with(
                    RetryAttempt::ZERO,
                    &upstream(Some(raw)),
                    Publication::Silent,
                    now,
                    || {
                        draws += 1;
                        Ok(0)
                    }
                )?,
                RetryDecision::Stop(RetryStop::ServerWait)
            );
            assert_eq!(draws, 0);
        }
        Ok(())
    }
    #[test]
    fn malformed_or_past_retry_after_uses_jitter_without_invented_delay() -> TestResult {
        let policy = policy(json!({}))?;
        let now = SystemTime::UNIX_EPOCH
            .checked_add(Duration::from_secs(1_700_000_000))
            .ok_or("time")?;
        let past = httpdate::fmt_http_date(SystemTime::UNIX_EPOCH);
        for raw in ["-1", "1.5", "invalid", "", past.as_str()] {
            assert_eq!(
                wait(policy.decide_with(
                    RetryAttempt::ZERO,
                    &upstream(Some(raw)),
                    Publication::Silent,
                    now,
                    || Ok(7)
                )?)?,
                Duration::from_nanos(7)
            );
        }
        Ok(())
    }
    #[test]
    fn entropy_rejection_is_unbiased_and_bounded_failure_never_becomes_zero() -> TestResult {
        let policy = policy(json!({}))?;
        let mut draws = 0;
        let delay = policy.decide_with(
            RetryAttempt::ZERO,
            &upstream(None),
            Publication::Silent,
            SystemTime::now(),
            || {
                draws += 1;
                Ok(if draws == 1 { u64::MAX } else { 7 })
            },
        )?;
        assert_eq!(wait(delay)?, Duration::from_nanos(7));
        assert_eq!(draws, 2);
        let mut draws = 0;
        assert!(
            policy
                .decide_with(
                    RetryAttempt::ZERO,
                    &upstream(None),
                    Publication::Silent,
                    SystemTime::now(),
                    || {
                        draws += 1;
                        Ok(u64::MAX)
                    }
                )
                .is_err()
        );
        assert_eq!(draws, limits::API_RANDOM_DRAWS);
        assert!(
            policy
                .decide_with(
                    RetryAttempt::ZERO,
                    &upstream(None),
                    Publication::Silent,
                    SystemTime::now(),
                    || Err(CoreError::Unavailable)
                )
                .is_err()
        );
        Ok(())
    }
    #[test]
    fn published_or_spent_or_nonretryable_attempts_never_draw_entropy() -> TestResult {
        let policy = policy(json!({}))?;
        for (attempt, error, publication, stop) in [
            (
                RetryAttempt::ZERO,
                upstream(None),
                Publication::Visible,
                RetryStop::Published,
            ),
            (
                RetryAttempt::try_from(u64::MAX)?,
                upstream(None),
                Publication::Silent,
                RetryStop::Attempts,
            ),
            (
                RetryAttempt::ZERO,
                ApiError::Connection,
                Publication::Silent,
                RetryStop::NotRetryable,
            ),
            (
                RetryAttempt::ZERO,
                ApiError::RunDeadline,
                Publication::Silent,
                RetryStop::NotRetryable,
            ),
        ] {
            let mut draws = 0;
            assert_eq!(
                policy.decide_with(attempt, &error, publication, SystemTime::now(), || {
                    draws += 1;
                    Ok(0)
                })?,
                RetryDecision::Stop(stop)
            );
            assert_eq!(draws, 0);
        }
        Ok(())
    }
}
