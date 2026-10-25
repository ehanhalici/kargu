//! Bounded endpoint metadata and revision identities for catalog preparation.

use crate::{
    error::CoreError,
    providers::{ApiEndpoint, CatalogEndpoint},
};
use serde::{Deserialize, Serialize};

/// Editor configuration publication identity, not a native store revision.
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct ConfigurationRevision(u64);

impl TryFrom<u64> for ConfigurationRevision {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Ok(Self(value))
    }
}
impl From<ConfigurationRevision> for u64 {
    fn from(value: ConfigurationRevision) -> Self {
        value.0
    }
}

/// Valid API base retaining the spelling needed for exact override detection.
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(super) struct CapturedApiBase {
    source: String,
    endpoint: ApiEndpoint,
}

impl TryFrom<String> for CapturedApiBase {
    type Error = CoreError;
    fn try_from(source: String) -> Result<Self, Self::Error> {
        if source.trim() != source {
            return Err(CoreError::InvalidValue {
                field: "CatalogApiBase",
            });
        }
        let endpoint = ApiEndpoint::try_from(source.clone())?;
        Ok(Self { source, endpoint })
    }
}

impl CapturedApiBase {
    pub fn matches_default(&self, default: &CatalogEndpoint) -> bool {
        fn parts(source: &str) -> (&str, Option<&str>) {
            match source.split_once('?') {
                Some((path, query)) => (path.trim_end_matches('/'), Some(query)),
                None => (source.trim_end_matches('/'), None),
            }
        }
        parts(&self.source) == parts(default.as_str())
    }
    pub fn endpoint(&self) -> &ApiEndpoint {
        &self.endpoint
    }
}

/// Declared URL path fragment; cannot replace the authority, query or fragment.
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(super) struct ModelsPath(String);

impl TryFrom<String> for ModelsPath {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > 1024
            || !value.starts_with('/')
            || value.starts_with("//")
            || value.chars().any(|c| c.is_control() || c.is_whitespace())
            || value.contains(['?', '#', '\\', '$', '{', '}'])
            || value.split('/').any(|part| matches!(part, "." | ".."))
        {
            return Err(CoreError::InvalidValue {
                field: "ModelsPath",
            });
        }
        Ok(Self(value))
    }
}
impl ModelsPath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A suffix controls compatibility selection, independently of an appended path.
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(super) struct CompatibleSuffix(ModelsPath);
impl TryFrom<String> for CompatibleSuffix {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        ModelsPath::try_from(value).map(Self)
    }
}
impl CompatibleSuffix {
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum ModelsAuth {
    #[default]
    Required,
    None,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub(super) struct NativeModels {
    pub path: ModelsPath,
    pub unless_suffix: Option<CompatibleSuffix>,
}
