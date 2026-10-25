//! Parsed API provider identities and endpoint metadata; no credentials live here.

use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// Human-readable provider label, distinct from its canonical namespace.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String")]
pub struct ProviderName(String);
impl TryFrom<String> for ProviderName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.trim().is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
            return Err(CoreError::InvalidValue {
                field: "ProviderName",
            });
        }
        Ok(Self(value))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(try_from = "String")]
pub(super) struct SourceDate(String);
impl TryFrom<String> for SourceDate {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let invalid = || CoreError::InvalidValue {
            field: "ProviderSourceDate",
        };
        let mut parts = value.split('-');
        let year = parts
            .next()
            .filter(|part| part.len() == 4)
            .ok_or_else(invalid)?
            .parse::<u16>()
            .map_err(|_| invalid())?;
        let month = parts
            .next()
            .filter(|part| part.len() == 2)
            .ok_or_else(invalid)?
            .parse::<u8>()
            .map_err(|_| invalid())?;
        let day = parts
            .next()
            .filter(|part| part.len() == 2)
            .ok_or_else(invalid)?
            .parse::<u8>()
            .map_err(|_| invalid())?;
        let days = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if year.is_multiple_of(400)
                || (year.is_multiple_of(4) && !year.is_multiple_of(100)) =>
            {
                29
            }
            2 => 28,
            _ => return Err(invalid()),
        };
        if year == 0 || day == 0 || day > days || parts.next().is_some() {
            return Err(invalid());
        }
        Ok(Self(value))
    }
}

/// Open provider namespace, distinct from model IDs and application backends.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(try_from = "String")]
pub struct ApiProviderId(String);
impl TryFrom<String> for ApiProviderId {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let value = value.trim().to_lowercase();
        if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
            return Err(CoreError::InvalidValue {
                field: "ApiProviderId",
            });
        }
        Ok(Self(value))
    }
}
impl ApiProviderId {
    /// Canonical namespace used only at storage/wire boundaries.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Valid HTTP(S) model endpoint, not a general webfetch permission.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct ApiEndpoint(url::Url);
impl TryFrom<String> for ApiEndpoint {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.len() > 8192
            || value.chars().any(char::is_control)
            || value.contains(['$', '{', '}'])
        {
            return Err(CoreError::InvalidValue {
                field: "ApiEndpoint",
            });
        }
        let url = url::Url::parse(&value).map_err(|_| CoreError::InvalidValue {
            field: "ApiEndpoint",
        })?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(CoreError::InvalidValue {
                field: "ApiEndpoint",
            });
        }
        Ok(Self(url))
    }
}
impl From<ApiEndpoint> for String {
    fn from(endpoint: ApiEndpoint) -> Self {
        endpoint.0.into()
    }
}
impl ApiEndpoint {
    /// URL for a captured HTTP adapter; never used in diagnostics by default.
    pub fn as_url(&self) -> &url::Url {
        &self.0
    }
}

/// Packaged address metadata. Templates are not executable API endpoints.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct CatalogEndpoint(String);
impl TryFrom<String> for CatalogEndpoint {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.len() > 8192 {
            return Err(CoreError::Limit);
        }
        let mut expanded = String::new();
        let mut remaining = value.as_str();
        while let Some((prefix, suffix)) = remaining.split_once("${") {
            let (name, rest) = suffix.split_once('}').ok_or(CoreError::InvalidValue {
                field: "CatalogEndpoint",
            })?;
            EnvironmentName::try_from(name.to_owned())?;
            expanded.push_str(prefix);
            expanded.push_str(if expanded.is_empty() {
                "https://template.invalid"
            } else {
                "template"
            });
            remaining = rest;
        }
        expanded.push_str(remaining);
        ApiEndpoint::try_from(expanded)?;
        Ok(Self(value))
    }
}
impl From<CatalogEndpoint> for String {
    fn from(endpoint: CatalogEndpoint) -> Self {
        endpoint.0
    }
}
impl CatalogEndpoint {
    /// Validated metadata spelling; unresolved templates are not HTTP targets.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A variable name only; environment values and secrets are never catalog data.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String")]
pub struct EnvironmentName(String);
impl TryFrom<String> for EnvironmentName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty()
            || value.len() > 256
            || !value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_')
        {
            return Err(CoreError::InvalidValue {
                field: "EnvironmentName",
            });
        }
        Ok(Self(value))
    }
}

/// Implemented wire families; provider IDs remain an open independent namespace.
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WireFamily {
    /// OpenAI-compatible Chat Completions.
    Openapi,
    /// OpenRouter's compatible API with nested reasoning/cache policy.
    Openrouter,
    /// Gemini's existing OpenAI-compatible endpoint.
    Gemini,
    /// Ollama's configured compatible chat and native model-list endpoint.
    Ollama,
    /// Anthropic Messages content-block wire.
    Anthropic,
}

impl WireFamily {
    /// Stable manifest key, separate from arbitrary provider namespaces.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Openapi => "openapi",
            Self::Openrouter => "openrouter",
            Self::Gemini => "gemini",
            Self::Ollama => "ollama",
            Self::Anthropic => "anthropic",
        }
    }
}
