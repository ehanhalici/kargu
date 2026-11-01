//! Unit-specific coordinates and detached sensor identities.

use crate::{constants::limits, error::CoreError};
use serde::{Deserialize, Serialize, Serializer};
use zeroize::Zeroizing;

macro_rules! quantity {
    ($name:ident, $minimum:expr, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "u64")]
        pub struct $name(u64);
        impl TryFrom<u64> for $name {
            type Error = CoreError;
            fn try_from(value: u64) -> Result<Self, CoreError> {
                if !($minimum..=i64::MAX as u64).contains(&value) {
                    return Err(CoreError::InvalidValue {
                        field: stringify!($name),
                    });
                }
                Ok(Self(value))
            }
        }
        impl $name {
            /// Return the exact integer in this quantity's own unit.
            pub fn get(self) -> u64 {
                self.0
            }
        }
    };
}
quantity!(
    SourceLine,
    1,
    "One-based source line, independent of visual wrapping."
);
quantity!(
    ScalarColumn,
    0,
    "Zero-based Unicode scalar column, independent of tab width."
);
quantity!(DocumentTick, 1, "Live editor document modification tick.");
quantity!(
    PublicationGeneration,
    1,
    "One captured checker report-function generation."
);
quantity!(
    LspVersion,
    0,
    "Version of the document known by the captured language server."
);
quantity!(
    StopGeneration,
    0,
    "Debugger stop epoch; references cannot cross this boundary."
);
quantity!(
    ThreadId,
    1,
    "Debugger thread identity within one connection."
);
quantity!(
    FrameId,
    0,
    "Debugger frame identity within one stop generation."
);

macro_rules! identity {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "String")]
        pub struct $name(String);
        impl TryFrom<String> for $name {
            type Error = CoreError;
            fn try_from(value: String) -> Result<Self, CoreError> {
                if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
                    return Err(CoreError::InvalidValue {
                        field: stringify!($name),
                    });
                }
                Ok(Self(value))
            }
        }
        impl $name {
            /// Borrow the captured opaque identity without resolving editor objects.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
    };
}
identity!(
    DocumentId,
    "Opaque live document identity, never inferred from a current buffer."
);
identity!(
    ServerId,
    "Language-server connection identity captured by the editor."
);
identity!(
    ImenuProviderId,
    "Major-mode/imenu provider identity, distinct from a language-server transport."
);
identity!(
    BackendId,
    "One checker identity, distinct from its report generation."
);
identity!(
    DebugConnectionId,
    "Debugger connection identity, distinct from thread and frame."
);
identity!(
    DiagnosticSource,
    "Diagnostic producer identity used for baseline comparison."
);
identity!(
    DiagnosticCode,
    "Optional diagnostic code, preserved independently of its message."
);

/// Bounded sensor text. Debug output cannot accidentally disclose its contents.
#[derive(Clone, Deserialize)]
#[serde(try_from = "String")]
pub struct SensorText(Zeroizing<String>);
impl std::fmt::Debug for SensorText {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("SensorText").field(&"[REDACTED]").finish()
    }
}
impl TryFrom<String> for SensorText {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let value = Zeroizing::new(value);
        if value.len() > limits::SENSOR_TEXT_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self(value))
    }
}
impl SensorText {
    /// Borrow bounded text for an explicit renderer or outgoing DTO.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl Serialize for SensorText {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}
