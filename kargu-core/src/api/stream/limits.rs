//! Independent parse-once byte and tool limits; editor settings may only lower caps.

use super::super::ApiError;
use serde::Deserialize;

macro_rules! limit {
    ($name:ident, $max:expr) => {
        #[derive(Clone, Copy, Deserialize)]
        #[serde(try_from = "usize")]
        pub(super) struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = ApiError;
            fn try_from(value: usize) -> Result<Self, ApiError> {
                if value == 0 || value > $max {
                    return Err(ApiError::Limit);
                }
                Ok(Self(value))
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self($max)
            }
        }
    };
}
limit!(RawBytes, 4 * 1024 * 1024);
limit!(LineBytes, 64 * 1024);
limit!(EventBytes, 1024 * 1024);
limit!(ToolCount, 64);
limit!(ArgumentBytes, 512 * 1024);

/// Captured stream policy, validated before network admission.
#[derive(Clone, Copy, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct StreamLimits {
    raw_bytes: RawBytes,
    line_bytes: LineBytes,
    event_bytes: EventBytes,
    tool_calls: ToolCount,
    argument_bytes: ArgumentBytes,
}
impl StreamLimits {
    pub(crate) fn raw(self) -> usize {
        self.raw_bytes.0
    }
    pub(super) fn line(self) -> usize {
        self.line_bytes.0
    }
    pub(super) fn event(self) -> usize {
        self.event_bytes.0
    }
    pub(super) fn calls(self) -> usize {
        self.tool_calls.0
    }
    pub(super) fn arguments(self) -> usize {
        self.argument_bytes.0
    }
}
