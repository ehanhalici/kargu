//! Bounded, non-printable configuration text and payload-free diagnostics.

use serde::{Deserialize, Serialize};
use std::num::NonZeroUsize;
use zeroize::Zeroizing;

/// Maximum UTF-8 source bytes accepted by the readonly parser port.
pub const MAX_SOURCE_BYTES: usize = 64 * 1024;

/// Editor refresh ordering identity; an echo, not native publication authority.
#[derive(Clone, Copy, Deserialize, Serialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(transparent)]
pub struct RefreshGeneration(u64);

/// One-based diagnostic line, never an arbitrary parser diagnostic string.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(transparent)]
pub struct SourceLine(NonZeroUsize);
impl SourceLine {
    pub(super) fn at(source: &str, offset: usize) -> Self {
        let prefix = source.get(..offset).unwrap_or_default();
        let line = prefix
            .bytes()
            .filter(|byte| *byte == b'\n')
            .count()
            .saturating_add(1);
        Self(NonZeroUsize::new(line).unwrap_or(NonZeroUsize::MIN))
    }
}
impl std::fmt::Display for SourceLine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

/// Parser errors never retain TOML source, values, paths or dependency errors.
#[derive(Debug, thiserror::Error)]
pub enum ConfigurationError {
    /// Invalid schema or syntax at a safe source coordinate.
    #[error("Invalid configuration at line {line}")]
    Invalid {
        /// One-based source coordinate only.
        line: SourceLine,
    },
    /// Independent source, collection or projection bound exceeded.
    #[error("Configuration resource limit exceeded")]
    Limit,
}
impl ConfigurationError {
    pub(super) fn at(source: &str, offset: usize) -> Self {
        Self::Invalid {
            line: SourceLine::at(source, offset),
        }
    }
    pub(super) fn from_toml(source: &str, error: toml::de::Error) -> Self {
        Self::at(
            source,
            error.span().map(|span| span.start).unwrap_or_default(),
        )
    }
}

/// Raw source can contain credentials: no Debug, Display or Serialize.
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub struct ConfigurationSource(pub(super) Zeroizing<String>);
impl TryFrom<String> for ConfigurationSource {
    type Error = ConfigurationError;
    fn try_from(source: String) -> Result<Self, Self::Error> {
        let source = Zeroizing::new(source);
        if source.len() > MAX_SOURCE_BYTES {
            return Err(ConfigurationError::Limit);
        }
        Ok(Self(source))
    }
}

/// Parsed field text may itself be an API key; generic serialization is absent.
#[derive(Clone, Deserialize)]
#[serde(try_from = "String")]
pub(super) struct ConfigText(Zeroizing<String>);
impl TryFrom<String> for ConfigText {
    type Error = ConfigurationError;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        let text = Zeroizing::new(text);
        if text.len() > MAX_SOURCE_BYTES {
            return Err(ConfigurationError::Limit);
        }
        Ok(Self(text))
    }
}
impl ConfigText {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
    // Deliberate private handoff to the existing editor config/credential owner.
    // Never a Serialize implementation or a diagnostic/metadata projection.
    pub(super) fn editor_value(&self) -> serde_json::Value {
        serde_json::Value::String(self.0.to_string())
    }
}

#[derive(Deserialize, Eq, PartialEq, Ord, PartialOrd)]
#[serde(try_from = "String")]
pub(super) struct ProviderName(String);
impl TryFrom<String> for ProviderName {
    type Error = ConfigurationError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
            return Err(ConfigurationError::at("", 0));
        }
        Ok(Self(value))
    }
}
impl ProviderName {
    pub(super) fn editor_value(self) -> serde_json::Value {
        serde_json::Value::String(self.0)
    }
}
