//! Explicit unlimited execution, independent of bounded approval and cleanup.

use crate::error::CoreError;
use std::time::Duration;
use tokio::time::Instant;

/// Validated optional wall-clock limit; None means genuinely unlimited.
#[derive(Clone, Copy)]
pub struct ExecutionTimeout(Option<Duration>);
impl ExecutionTimeout {
    /// No execution deadline; cancellation and resource bounds still apply.
    pub const UNLIMITED: Self = Self(None);
    /// Captured duration, without substituting an artificial far-future timeout.
    pub fn duration(self) -> Option<Duration> {
        self.0
    }
    /// Derive an absolute deadline once at admission or process startup.
    pub fn start(self) -> Result<Deadline, CoreError> {
        self.0
            .map(|duration| {
                Instant::now()
                    .checked_add(duration)
                    .ok_or(CoreError::ArithmeticOverflow)
            })
            .transpose()
            .map(Deadline)
    }
}
impl TryFrom<Option<Duration>> for ExecutionTimeout {
    type Error = CoreError;
    fn try_from(value: Option<Duration>) -> Result<Self, CoreError> {
        if value.is_some_and(|duration| {
            duration.is_zero() || Instant::now().checked_add(duration).is_none()
        }) {
            return Err(CoreError::InvalidValue {
                field: "ExecutionTimeout",
            });
        }
        Ok(Self(value))
    }
}
impl TryFrom<Duration> for ExecutionTimeout {
    type Error = CoreError;
    fn try_from(value: Duration) -> Result<Self, CoreError> {
        Self::try_from(Some(value))
    }
}

/// Optional absolute deadline with one consistent cap/check/wait implementation.
#[derive(Clone, Copy)]
pub struct Deadline(Option<Instant>);
impl Deadline {
    /// Whether a configured finite deadline has elapsed.
    pub fn expired(self) -> bool {
        self.0.is_some_and(|at| Instant::now() >= at)
    }
    /// Cap a finite UI/sensor deadline, including for an unlimited execution.
    pub fn cap(self, at: Instant) -> Instant {
        self.0.map_or(at, |limit| limit.min(at))
    }
    /// Earliest configured deadline; unlimited adds no extra bound.
    pub fn earliest(self, other: Self) -> Self {
        Self(match (self.0, other.0) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        })
    }
    /// Wait indefinitely when execution is unlimited; still cancellation-safe.
    pub async fn elapsed(self) {
        match self.0 {
            Some(at) => tokio::time::sleep_until(at).await,
            None => std::future::pending().await,
        }
    }
}
