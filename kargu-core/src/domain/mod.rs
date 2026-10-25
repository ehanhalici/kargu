//! Private, validated identifiers, coordinates, counters and model values.
//!
//! Units cannot be interchanged in an internal API:
//! ```compile_fail
//! use kargu_core::domain::{TokenCount, StepCount};
//! fn mix(tokens: TokenCount, steps: StepCount) { let _ = tokens.checked_add(steps); }
//! ```

use crate::{constants::limits, error::CoreError};
use serde::{Deserialize, Serialize};

mod api;
pub use api::ApiPageBytes;
mod deadline;
pub use deadline::{Deadline, ExecutionTimeout, IdleTimeout};
mod output;
pub use output::{CapturePolicy, CaptureStop, RecordLimit, SuccessCodes};

/// Positive OS process identity, for display only; never accepted as signal authority.
#[derive(Clone, Copy, Serialize)]
pub struct ProcessId(u32);
impl TryFrom<u32> for ProcessId {
    type Error = CoreError;
    fn try_from(value: u32) -> Result<Self, CoreError> {
        if value == 0 {
            return Err(CoreError::InvalidValue { field: "ProcessId" });
        }
        Ok(Self(value))
    }
}

/// Retained process output capacity, distinct from nonempty transport/page limits.
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(try_from = "usize")]
pub struct OutputLimit(usize);
impl Default for OutputLimit {
    fn default() -> Self {
        Self(limits::PROCESS_OUTPUT_BYTES)
    }
}
impl TryFrom<usize> for OutputLimit {
    type Error = CoreError;
    fn try_from(value: usize) -> Result<Self, CoreError> {
        if value > limits::PROCESS_OUTPUT_MAX_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self(value))
    }
}
impl OutputLimit {
    /// Exact retained capacity; zero disables retention without stopping pipe drain.
    pub fn as_usize(self) -> usize {
        self.0
    }
}

/// Which bounded process output interval remains available after truncation.
#[derive(Clone, Copy, Default, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputRetention {
    /// Initial output, used by structured one-shot tool adapters.
    #[default]
    Prefix,
    /// Recent output, used by live foreground/background job logs.
    Tail,
}

/// Explicit stderr routing; structured adapters keep streams separate by default.
#[derive(Clone, Copy, Default, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StderrPolicy {
    /// Independent stdout/stderr archives.
    #[default]
    Separate,
    /// One OS pipe shared by both descriptors, preserving their observed ordering.
    Merge,
}

macro_rules! identity {
    ($name:ident, $prefix:literal, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
        #[serde(try_from = "String")]
        pub struct $name(String);
        impl $name {
            /// Allocate a fresh opaque identity; identity alone is not execution authority.
            pub fn new() -> Self {
                Self(format!("{}{}", $prefix, uuid::Uuid::new_v4()))
            }
            /// Borrow its wire representation.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }
        impl TryFrom<String> for $name {
            type Error = CoreError;
            fn try_from(value: String) -> Result<Self, Self::Error> {
                let suffix = value.strip_prefix($prefix).ok_or(CoreError::InvalidValue {
                    field: stringify!($name),
                })?;
                uuid::Uuid::parse_str(suffix).map_err(|_| CoreError::InvalidValue {
                    field: stringify!($name),
                })?;
                Ok(Self(value))
            }
        }
    };
}
identity!(
    ApplicationId,
    "app_",
    "Application identity, distinct from a session or run."
);
identity!(SessionId, "sess_", "Conversation identity.");
identity!(RunId, "run_", "One execution attempt identity.");
identity!(ClaimId, "claim_", "Application admission claim identity.");
identity!(
    ToolCallId,
    "call_",
    "One committed native tool invocation identity."
);
identity!(
    ApprovalId,
    "approval_",
    "Single-use, server-held approval identity."
);
identity!(JobId, "job_", "One supervised subprocess identity.");
identity!(ProbeId, "probe_", "One circuit half-open probe lease.");
identity!(
    CircuitId,
    "circuit_",
    "One non-reusable circuit accounting owner."
);
identity!(
    BudgetId,
    "budget_",
    "One non-reusable API accounting lifetime."
);

macro_rules! counter {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(
            Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
        )]
        #[serde(try_from = "u64")]
        pub struct $name(u64);
        impl $name {
            /// Empty value in this unit.
            pub const ZERO: Self = Self(0);
            /// Borrow the underlying count at a serialization or library boundary.
            pub const fn as_u64(self) -> u64 {
                self.0
            }
            /// Add in the same unit or report overflow.
            pub fn checked_add(self, rhs: Self) -> Result<Self, CoreError> {
                self.0
                    .checked_add(rhs.0)
                    .map(Self)
                    .ok_or(CoreError::ArithmeticOverflow)
            }
            /// Increment without saturation or wraparound.
            pub fn next(self) -> Result<Self, CoreError> {
                self.0
                    .checked_add(1)
                    .map(Self)
                    .ok_or(CoreError::ArithmeticOverflow)
            }
        }
        impl TryFrom<u64> for $name {
            type Error = CoreError;
            fn try_from(value: u64) -> Result<Self, CoreError> {
                Ok(Self(value))
            }
        }
    };
}
counter!(Generation, "Application run generation.");
counter!(RequestSequence, "Connection-owned reverse RPC sequence.");
counter!(
    ConfigRevision,
    "Captured configuration publication revision."
);
counter!(PolicyRevision, "Captured permission policy revision.");
counter!(TokenCount, "Token quantity with checked arithmetic.");
counter!(
    RequestCount,
    "Charged API attempts, independent of retries or tool steps."
);
counter!(CompactionCount, "Started logical context compactions.");
counter!(
    InputTokens,
    "Input usage, independent of output/reasoning usage."
);
counter!(
    OutputTokens,
    "Output usage, which may already include reasoning."
);
counter!(
    CachedTokens,
    "Cache usage, interpreted by provider billing rules."
);
counter!(
    ReasoningTokens,
    "Reasoning usage; not automatically added to output usage."
);
counter!(StepCount, "Tool execution steps, never a token quantity.");
counter!(
    UpstreamFailures,
    "Consecutive classified upstream failures."
);
counter!(
    CircuitRevision,
    "Circuit lease revision, independent of run generations."
);
counter!(
    CircuitProjectionSequence,
    "Connection-ordered circuit UI observations, distinct from lease revisions."
);
counter!(
    RetryAttempt,
    "Request retry count, independent of tool steps."
);
counter!(
    MicroUsd,
    "Integer micro-dollars; pricing fractions are retained by the billing service."
);
counter!(
    ByteOffset,
    "Zero-based absolute byte offset in a retained stream."
);
counter!(
    OutputRecords,
    "Completed stdout records, independent of document line coordinates."
);
counter!(
    ColumnIndex,
    "Zero-based Unicode scalar column, not a visual column."
);

/// A positive line number, independent of byte and column indices.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64")]
pub struct LineNumber(u64);
impl TryFrom<u64> for LineNumber {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 {
            Err(CoreError::InvalidValue {
                field: "LineNumber",
            })
        } else {
            Ok(Self(value))
        }
    }
}
impl TryFrom<usize> for LineNumber {
    type Error = CoreError;
    fn try_from(value: usize) -> Result<Self, CoreError> {
        Self::try_from(u64::try_from(value).map_err(|_| CoreError::ArithmeticOverflow)?)
    }
}
impl LineNumber {
    /// One-based wire representation.
    pub const fn as_u64(self) -> u64 {
        self.0
    }
}

/// Positive tool invocation budget, independent of StepCount and TokenCount.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64")]
pub struct ToolCallLimit(u64);
impl Default for ToolCallLimit {
    fn default() -> Self {
        Self(limits::TOOL_CALLS)
    }
}
impl TryFrom<u64> for ToolCallLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 {
            Err(CoreError::InvalidValue {
                field: "ToolCallLimit",
            })
        } else {
            Ok(Self(value))
        }
    }
}
impl ToolCallLimit {
    /// Compare in the correct unit, without unchecked arithmetic.
    pub fn permits(self, spent: StepCount) -> bool {
        spent.as_u64() < self.0
    }
}

/// Positive byte bound, used only at framing, allocation and IO boundaries.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "usize")]
pub struct ByteLimit(usize);
impl TryFrom<usize> for ByteLimit {
    type Error = CoreError;
    fn try_from(value: usize) -> Result<Self, CoreError> {
        if value == 0 {
            Err(CoreError::InvalidValue { field: "ByteLimit" })
        } else {
            Ok(Self(value))
        }
    }
}
impl ByteLimit {
    /// Extract at a codec or allocation boundary.
    pub const fn as_usize(self) -> usize {
        self.0
    }
    /// Protocol maximum, sourced from shared constants.
    pub const WIRE_MAX: Self = Self(limits::MAX_FRAME_BYTES);
}

/// Validated canonical tool or alias name; it is not an arbitrary RPC method.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct ToolName(String);
impl TryFrom<String> for ToolName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty()
            || value.len() > limits::TOOL_NAME_BYTES
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(CoreError::InvalidValue { field: "ToolName" });
        }
        Ok(Self(value))
    }
}
impl ToolName {
    /// Canonical wire name.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Opaque, bounded owner identity for transport-only reverse calls.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestScope(String);
impl RequestScope {
    /// Borrow a validated opaque owner scope at the transport boundary.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for RequestScope {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty() || value.len() > limits::REQUEST_SCOPE_BYTES {
            Err(CoreError::InvalidValue {
                field: "RequestScope",
            })
        } else {
            Ok(Self(value))
        }
    }
}

/// Finite model parameter whose range is proven on ingestion.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "f64")]
pub struct BoundedFloat<const MIN: i32, const MAX: i32>(f64);
impl<const MIN: i32, const MAX: i32> TryFrom<f64> for BoundedFloat<MIN, MAX> {
    type Error = CoreError;
    fn try_from(value: f64) -> Result<Self, CoreError> {
        if MIN > MAX || !value.is_finite() || value < f64::from(MIN) || value > f64::from(MAX) {
            Err(CoreError::InvalidValue {
                field: "BoundedFloat",
            })
        } else {
            Ok(Self(value))
        }
    }
}
impl<const MIN: i32, const MAX: i32> BoundedFloat<MIN, MAX> {
    /// Extract only when building a validated provider payload.
    pub const fn as_f64(self) -> f64 {
        self.0
    }
}

/// User preference; model capability validation remains the provider adapter's job.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningEffort {
    /// Leave the provider/model default unchanged.
    ProviderDefault,
    /// Explicitly disable when the model supports disabling.
    Off,
    /// Minimal effort when supported.
    Minimal,
    /// Low effort.
    Low,
    /// Medium effort.
    Medium,
    /// High effort.
    High,
    /// Extra high effort when supported.
    Xhigh,
    /// Maximum supported effort, never silently mapped to High.
    Max,
    /// Explicit validated token budget, not an effort label.
    CustomBudget(TokenCount),
}

/// Explicit effect classification, independent of a tool's display name.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolSafetyLevel {
    /// Proven read-only executor.
    SafeReadOnly,
    /// Writes files through the edit transaction service.
    MutatesState,
    /// General subprocess, debugger evaluation or execution control.
    ExecutesArbitraryCode,
}
