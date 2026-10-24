//! Parsed settings are not provider/model-name heuristics.

use crate::api::ApiError;
use serde::{Deserialize, Deserializer};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "f64")]
pub(super) struct Temperature(f64);
impl TryFrom<f64> for Temperature {
    type Error = ApiError;
    fn try_from(value: f64) -> Result<Self, ApiError> {
        if !value.is_finite() || !(0.0..=2.0).contains(&value) {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(value))
    }
}
impl Temperature {
    pub fn as_f64(self) -> f64 {
        self.0
    }
}

#[derive(Clone, Eq, Ord, PartialEq, PartialOrd, Deserialize)]
#[serde(try_from = "String")]
pub(super) struct ParameterName(String);
impl TryFrom<String> for ParameterName {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, ApiError> {
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(value))
    }
}
impl ParameterName {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Deserialize)]
#[serde(try_from = "Vec<ParameterName>")]
pub(super) struct Parameters(BTreeSet<ParameterName>);
impl TryFrom<Vec<ParameterName>> for Parameters {
    type Error = ApiError;
    fn try_from(value: Vec<ParameterName>) -> Result<Self, ApiError> {
        if value.len() > 128 {
            return Err(ApiError::Limit);
        }
        Ok(Self(value.into_iter().collect()))
    }
}
impl Parameters {
    pub fn contains(&self, name: &str) -> bool {
        self.0.iter().any(|parameter| parameter.as_str() == name)
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum OutputField {
    MaxTokens,
    MaxCompletionTokens,
}
impl OutputField {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MaxTokens => "max_tokens",
            Self::MaxCompletionTokens => "max_completion_tokens",
        }
    }
}

/// Missing and explicit null must remain different during defaults merging.
#[derive(Default)]
pub(super) enum Override<T> {
    #[default]
    Unset,
    Set(T),
}
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Override<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        T::deserialize(deserializer).map(Self::Set)
    }
}

/// Ordered format/provider patch; explicit null disables an inherited value.
#[derive(Default, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct DefaultsPatch {
    #[serde(default)]
    pub(super) max_output_key: Override<Option<OutputField>>,
    #[serde(default)]
    pub(super) sampling_parameters: Override<Option<Parameters>>,
    #[serde(default)]
    pub(super) reasoning_disallows_temperature: Override<bool>,
}

/// Explicit catalog wire location for reasoning controls, not a provider guess.
#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ReasoningShape {
    /// Chat-completions top-level effort field.
    #[default]
    Effort,
    /// Nested effort and optional token budget.
    Nested,
    /// Provider thinking budget object.
    Thinking,
}

pub(super) struct EffortName(String);
#[derive(Default, Deserialize)]
#[serde(try_from = "String")]
pub(super) enum ReasoningSelection {
    #[default]
    ProviderDefault,
    Disabled,
    Effort(EffortName),
}
impl TryFrom<String> for ReasoningSelection {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, ApiError> {
        let value = value.trim();
        if value.len() > 64 || value.chars().any(char::is_control) {
            return Err(ApiError::InvalidRequest);
        }
        match value.to_ascii_lowercase().as_str() {
            "" | "nil" => Ok(Self::ProviderDefault),
            "off" => Ok(Self::Disabled),
            _ => Ok(Self::Effort(EffortName(value.to_owned()))),
        }
    }
}
impl ReasoningSelection {
    pub fn effort(&self) -> Option<&str> {
        match self {
            Self::Effort(name) => Some(&name.0),
            _ => None,
        }
    }
}
