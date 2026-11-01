//! Normalize editor-specific severity facts at the native boundary.
use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// Canonical diagnostic severity, independent of editor category symbols.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Ord, PartialOrd, Serialize)]
#[serde(try_from = "SeverityInput", rename_all = "snake_case")]
pub enum Severity {
    /// Compiler or checker error.
    Error,
    /// Warning without a compiler error.
    Warning,
    /// Supplemental note.
    Note,
    /// Informational finding.
    Info,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Canonical {
    Error,
    Warning,
    Note,
    Info,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum SeverityInput {
    Canonical(Canonical),
    Flymake(FlymakeInput),
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FlymakeInput {
    flymake: FlymakeRank,
}
#[derive(Deserialize)]
#[serde(try_from = "u64")]
struct FlymakeRank(u64);
impl TryFrom<u64> for FlymakeRank {
    type Error = CoreError;
    fn try_from(rank: u64) -> Result<Self, CoreError> {
        if !(1..=i64::MAX as u64).contains(&rank) {
            return Err(CoreError::InvalidValue {
                field: "FlymakeRank",
            });
        }
        Ok(Self(rank))
    }
}
/// Raw editor grading is distinguished from a client's preclassified label.
#[derive(Deserialize)]
#[serde(transparent)]
pub(super) struct SeverityObservation(SeverityInput);
impl SeverityObservation {
    pub(super) fn classify(self) -> (Severity, bool) {
        let native = matches!(&self.0, SeverityInput::Flymake(_));
        let severity = match self.0 {
            SeverityInput::Canonical(Canonical::Error) => Severity::Error,
            SeverityInput::Canonical(Canonical::Warning) => Severity::Warning,
            SeverityInput::Canonical(Canonical::Note) => Severity::Note,
            SeverityInput::Canonical(Canonical::Info) => Severity::Info,
            // Flymake defines note=1, warning=2, error=3. Higher custom ranks
            // are at least as severe as an error, never an informational fallback.
            SeverityInput::Flymake(FlymakeInput {
                flymake: FlymakeRank(1),
            }) => Severity::Note,
            SeverityInput::Flymake(FlymakeInput {
                flymake: FlymakeRank(2),
            }) => Severity::Warning,
            SeverityInput::Flymake(_) => Severity::Error,
        };
        (severity, native)
    }
}
impl TryFrom<SeverityInput> for Severity {
    type Error = CoreError;
    fn try_from(input: SeverityInput) -> Result<Self, CoreError> {
        Ok(SeverityObservation(input).classify().0)
    }
}
