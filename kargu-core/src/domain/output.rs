//! Typed record capture and accepted process exit semantics.

use super::{OutputRecords, OutputRetention};
use crate::{constants::limits, error::CoreError};
use serde::{Deserialize, Serialize};

/// Positive bounded stdout record count; distinct from bytes or file coordinates.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct RecordLimit(u64);
impl TryFrom<u64> for RecordLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 || value > limits::PROCESS_RECORDS {
            return Err(CoreError::InvalidValue {
                field: "RecordLimit",
            });
        }
        Ok(Self(value))
    }
}
impl RecordLimit {
    /// Serialization/hash boundary in record units, never bytes.
    pub fn as_u64(self) -> u64 {
        self.0
    }
    pub(crate) fn reached(self, observed: OutputRecords) -> bool {
        observed.as_u64() >= self.0
    }
}

/// Capture mode; record capture is intrinsically prefix-only, never rolling tail.
#[derive(Clone, Copy, Debug)]
pub enum CapturePolicy {
    /// Retain bounded output without ending the process when retention fills.
    Retain(OutputRetention),
    /// Freeze a complete-record prefix, then terminate and drain the producer.
    Records(RecordLimit),
}
impl Default for CapturePolicy {
    fn default() -> Self {
        Self::Retain(OutputRetention::Prefix)
    }
}
impl CapturePolicy {
    /// Effective archive retention; invalid tail-plus-record states cannot be formed.
    pub fn retention(self) -> OutputRetention {
        match self {
            Self::Retain(retention) => retention,
            Self::Records(_) => OutputRetention::Prefix,
        }
    }
    /// Optional producer-stop budget, separate from retained byte capacity.
    pub fn records(self) -> Option<RecordLimit> {
        match self {
            Self::Retain(_) => None,
            Self::Records(limit) => Some(limit),
        }
    }
}

/// Why explicit record capture stopped accepting stdout, not an OS exit code.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureStop {
    /// The requested complete-record prefix was captured.
    Records,
    /// Byte retention filled before that prefix was available.
    Bytes,
}

/// Adapter-selected accepted exit semantics, bound to the exact action.
#[derive(Clone, Copy, Debug, Default, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SuccessCodes {
    /// Ordinary command success.
    #[default]
    Zero,
    /// Search-style success including a no-match exit status.
    ZeroOrOne,
}
impl SuccessCodes {
    pub(crate) fn accepts(self, status: &std::process::ExitStatus) -> bool {
        status.success() || (matches!(self, Self::ZeroOrOne) && status.code() == Some(1))
    }
}
