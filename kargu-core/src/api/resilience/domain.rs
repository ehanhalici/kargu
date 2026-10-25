//! Captured, private policy units. Invalid configuration fails before IO.

use crate::{constants::limits, error::CoreError};
use reqwest::StatusCode;
use serde::Deserialize;
use std::{collections::HashSet, time::Duration};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Deserialize)]
#[serde(try_from = "u64")]
pub(super) struct RetryLimit(u64);
impl TryFrom<u64> for RetryLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value > limits::API_RETRIES {
            return Err(CoreError::InvalidValue {
                field: "RetryLimit",
            });
        }
        Ok(Self(value))
    }
}
impl Default for RetryLimit {
    fn default() -> Self {
        Self(5)
    }
}
impl RetryLimit {
    pub fn count(self) -> u64 {
        self.0
    }
}

macro_rules! interval {
    ($name:ident, $minimum:expr, $maximum:expr, $default:expr) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Deserialize)]
        #[serde(try_from = "u64")]
        pub(super) struct $name(Duration);
        impl TryFrom<u64> for $name {
            type Error = CoreError;
            fn try_from(value: u64) -> Result<Self, CoreError> {
                if !($minimum..=$maximum).contains(&value) {
                    return Err(CoreError::InvalidValue {
                        field: stringify!($name),
                    });
                }
                Ok(Self(Duration::from_millis(value)))
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self(Duration::from_millis($default))
            }
        }
        impl $name {
            pub fn duration(self) -> Duration {
                self.0
            }
        }
    };
}
interval!(BackoffBase, 1, limits::API_BACKOFF_MS, 1_000);
interval!(BackoffCap, 1, limits::API_BACKOFF_MS, 32_000);
interval!(ServerWaitLimit, 0, limits::API_SERVER_WAIT_MS, 60_000);
interval!(CircuitCooldown, 1, limits::API_SERVER_WAIT_MS, 30_000);

/// Only allowlisted transient statuses may be configured for automatic replay.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Deserialize)]
#[serde(try_from = "u16")]
pub(super) struct RetryStatus(u16);
impl TryFrom<u16> for RetryStatus {
    type Error = CoreError;
    fn try_from(value: u16) -> Result<Self, CoreError> {
        if !matches!(value, 429 | 500 | 502 | 503 | 504 | 529) {
            return Err(CoreError::InvalidValue {
                field: "RetryStatus",
            });
        }
        Ok(Self(value))
    }
}
impl RetryStatus {
    pub fn matches(self, status: StatusCode) -> bool {
        self.0 == status.as_u16()
    }
}
fn default_statuses() -> Vec<RetryStatus> {
    [429, 500, 502, 503, 504, 529]
        .into_iter()
        .map(RetryStatus)
        .collect()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RetryDto {
    #[serde(default)]
    pub retry_max: RetryLimit,
    #[serde(default = "default_statuses")]
    pub statuses: Vec<RetryStatus>,
    #[serde(default)]
    pub backoff_base_ms: BackoffBase,
    #[serde(default)]
    pub backoff_cap_ms: BackoffCap,
    #[serde(default)]
    pub retry_after_max_ms: ServerWaitLimit,
}
impl RetryDto {
    pub fn consistent(&self) -> bool {
        let unique: HashSet<_> = self.statuses.iter().collect();
        self.statuses.len() <= 6
            && unique.len() == self.statuses.len()
            && self.backoff_base_ms.duration() <= self.backoff_cap_ms.duration()
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Deserialize)]
#[serde(try_from = "u64")]
struct FailureThreshold(u64);
impl TryFrom<u64> for FailureThreshold {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if !(1..=limits::API_CIRCUIT_FAILURES).contains(&value) {
            return Err(CoreError::InvalidValue {
                field: "FailureThreshold",
            });
        }
        Ok(Self(value))
    }
}
impl Default for FailureThreshold {
    fn default() -> Self {
        Self(4)
    }
}

/// Frozen breaker configuration; reconfiguration cannot mutate issued leases.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CircuitPolicy {
    #[serde(default)]
    failure_threshold: FailureThreshold,
    #[serde(default)]
    cooldown_ms: CircuitCooldown,
}
impl CircuitPolicy {
    pub(super) fn threshold(self) -> u64 {
        self.failure_threshold.0
    }
    pub(super) fn cooldown(self) -> Duration {
        self.cooldown_ms.duration()
    }
}

/// Captured duration with no floating point, wall-clock identity or payload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryDelay(pub(super) Duration);
impl RetryDelay {
    /// Borrow only at the timer/DTO boundary.
    pub fn duration(self) -> Duration {
        self.0
    }
}

/// Any model-visible delta forbids automatic replay, even without tool execution.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Publication {
    /// No model-visible effects have been delivered.
    Silent,
    /// Some text/reasoning/tool-call delta was published.
    Visible,
}
