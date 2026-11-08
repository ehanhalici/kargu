//! Per-conversation provider/model/effort choice with expected-revision commits.
//!
//! The editor sends a complete desired selection and the revision it observed.
//! The actor is the only writer; a stale or busy intent leaves the committed
//! value untouched.  Membership in a catalog stays a picker concern; this
//! store validates representation, bounds and admission only.

use crate::{error::CoreError, providers::ApiProviderId};
use serde::{Deserialize, Serialize};

/// Monotonic committed-selection revision within one conversation.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64")]
pub struct SelectionRevision(u64);
impl SelectionRevision {
    /// Revision of a newly created conversation's empty choice.
    pub const ZERO: Self = Self(0);
    /// Borrow the revision at a serialization boundary.
    pub const fn as_u64(self) -> u64 {
        self.0
    }
    fn next(self) -> Result<Self, CoreError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(CoreError::ArithmeticOverflow)
    }
}
impl TryFrom<u64> for SelectionRevision {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        Ok(Self(value))
    }
}

const TEXT_BYTES: usize = 512;

fn printable(value: &str, field: &'static str) -> Result<(), CoreError> {
    if value.is_empty()
        || value.len() > TEXT_BYTES
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return Err(CoreError::InvalidValue { field });
    }
    Ok(())
}

/// Explicit model identifier exactly as the provider lists it.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct ModelChoice(String);
impl ModelChoice {
    /// Borrow the identifier at a policy boundary.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for ModelChoice {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        printable(&value, "ModelChoice")?;
        Ok(Self(value))
    }
}

/// Provider-declared effort label, never a Lisp symbol or inferred level.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct EffortLabel(String);
impl TryFrom<String> for EffortLabel {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        printable(&value, "EffortLabel")?;
        if value.eq_ignore_ascii_case("off") || value.eq_ignore_ascii_case("inherit") {
            return Err(CoreError::InvalidValue {
                field: "EffortLabel",
            });
        }
        Ok(Self(value))
    }
}

/// Inherited configuration, explicit reasoning-off and a named level stay distinct.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum EffortChoice {
    /// Use the configured or model default.
    #[default]
    Inherit,
    /// Explicitly omit reasoning.
    Off,
    /// One provider-declared effort label.
    Named {
        /// Exact label.
        name: EffortLabel,
    },
}

/// One complete immutable choice; absent fields mean "no explicit override".
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    /// Explicit provider, or none to inherit configuration.
    #[serde(default)]
    pub provider: Option<ApiProviderId>,
    /// Explicit model, or none to inherit configuration.
    #[serde(default)]
    pub model: Option<ModelChoice>,
    /// Effort override.
    #[serde(default)]
    effort: EffortChoice,
}

/// Committed selection and the revision that produced it.
#[derive(Clone, Debug, Default, Serialize)]
pub struct SessionSelection {
    revision: SelectionRevision,
    selection: Selection,
}
impl SessionSelection {
    /// Current revision.
    pub fn revision(&self) -> SelectionRevision {
        self.revision
    }
    /// Current committed value.
    pub fn selection(&self) -> &Selection {
        &self.selection
    }
    /// Replace the value only from the exact observed revision while unlocked.
    pub fn commit(
        &mut self,
        expected: SelectionRevision,
        desired: Selection,
        locked: bool,
    ) -> Result<(), CoreError> {
        if locked {
            return Err(CoreError::Busy);
        }
        if expected != self.revision {
            return Err(CoreError::StaleOwner);
        }
        if desired != self.selection {
            self.revision = self.revision.next()?;
            self.selection = desired;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(value: serde_json::Value) -> Result<Selection, serde_json::Error> {
        serde_json::from_value(value)
    }

    #[test]
    fn effort_states_and_bounds_are_explicit() -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(parse(json!({}))?.effort, EffortChoice::Inherit);
        assert_eq!(
            parse(json!({"effort":{"kind":"off"}}))?.effort,
            EffortChoice::Off
        );
        let named = parse(json!({"effort":{"kind":"named","name":"high"}}))?;
        assert!(matches!(named.effort, EffortChoice::Named { .. }));
        for bad in [
            json!({"effort":{"kind":"named","name":"off"}}),
            json!({"effort":{"kind":"named","name":""}}),
            json!({"effort":{"kind":"named","name":" low"}}),
            json!({"model":"a\nb"}),
            json!({"model":"x".repeat(TEXT_BYTES + 1)}),
            json!({"provider":""}),
            json!({"unknown":true}),
        ] {
            assert!(parse(bad).is_err());
        }
        Ok(())
    }

    #[test]
    fn stale_busy_and_noop_commits_keep_the_revision() -> Result<(), Box<dyn std::error::Error>> {
        let mut store = SessionSelection::default();
        let desired = parse(json!({"provider":"openai","model":"gpt-x"}))?;
        assert!(matches!(
            store.commit(SelectionRevision::ZERO, desired.clone(), true),
            Err(CoreError::Busy)
        ));
        assert_eq!(store.revision(), SelectionRevision::ZERO);
        store.commit(SelectionRevision::ZERO, desired.clone(), false)?;
        assert_eq!(store.revision().as_u64(), 1);
        assert!(matches!(
            store.commit(SelectionRevision::ZERO, Selection::default(), false),
            Err(CoreError::StaleOwner)
        ));
        assert_eq!(store.selection(), &desired);
        store.commit(store.revision(), desired, false)?;
        assert_eq!(store.revision().as_u64(), 1);
        Ok(())
    }
}
