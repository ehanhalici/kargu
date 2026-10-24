//! Versioned embedded API provider catalog and credential-free UI snapshots.

mod domain;
use domain::SourceDate;
pub use domain::{
    ApiEndpoint, ApiProviderId, CatalogEndpoint, EnvironmentName, ProviderName, WireFamily,
};

use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

/// Packaged metadata, never remote discovery or a credential source.
pub const EMBEDDED_MANIFEST: &str = include_str!("../../assets/providers.json");

/// Validated provider metadata. Missing/unsupported wire is not a usable backend.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct ProviderDefinition {
    id: ApiProviderId,
    name: ProviderName,
    api: CatalogEndpoint,
    models_api: CatalogEndpoint,
    env: Vec<EnvironmentName>,
    npm: String,
    format: Option<WireFamily>,
    prompt_caching: bool,
    #[serde(default)]
    keyless: bool,
    #[serde(default)]
    local: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage_api: Option<CatalogEndpoint>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    extra_headers: BTreeMap<String, HeaderTemplate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    models_auth: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum HeaderTemplate {
    Literal(String),
    Binding(HeaderBinding),
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HeaderBinding {
    binding: Binding,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum Binding {
    AppUrl,
    Session,
}
impl ProviderDefinition {
    /// Canonical API namespace, never an installed-application backend ID.
    pub fn id(&self) -> &ApiProviderId {
        &self.id
    }
    /// Implemented wire, or explicit unsupported metadata.
    pub fn family(&self) -> Option<WireFamily> {
        self.format
    }
    /// Default endpoint before explicit user overrides.
    pub fn endpoint(&self) -> &CatalogEndpoint {
        &self.api
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    source_date: SourceDate,
    formats: BTreeMap<String, Value>,
    providers: Vec<ProviderDefinition>,
}

/// Immutable parsed catalog. Runtime extension/remote data is a separate layer.
pub struct ProviderCatalog {
    source_date: SourceDate,
    revision: CatalogRevision,
    formats: BTreeMap<String, Value>,
    providers: BTreeMap<ApiProviderId, ProviderDefinition>,
}

#[derive(Serialize)]
#[serde(transparent)]
struct CatalogRevision(String);
impl TryFrom<&str> for ProviderCatalog {
    type Error = CoreError;
    fn try_from(source: &str) -> Result<Self, CoreError> {
        if source.len() > 512 * 1024 {
            return Err(CoreError::Limit);
        }
        let manifest: Manifest =
            serde_json::from_str(source).map_err(|_| CoreError::InvalidValue {
                field: "ProviderManifest",
            })?;
        if manifest.schema_version != 1
            || manifest.providers.is_empty()
            || manifest.providers.len() > 512
            || manifest.formats.len() > 32
            || manifest.formats.values().any(|format| !format.is_object())
        {
            return Err(CoreError::InvalidValue {
                field: "ProviderManifest",
            });
        }
        let mut providers = BTreeMap::new();
        for provider in manifest.providers {
            if provider.env.len() > 16
                || providers.contains_key(provider.id())
                || provider
                    .family()
                    .is_some_and(|family| !manifest.formats.contains_key(family.as_str()))
            {
                return Err(CoreError::InvalidValue {
                    field: "ProviderManifest",
                });
            }
            providers.insert(provider.id.clone(), provider);
        }
        Ok(Self {
            source_date: manifest.source_date,
            revision: CatalogRevision(format!("{:x}", Sha256::digest(source.as_bytes()))),
            formats: manifest.formats,
            providers,
        })
    }
}
impl ProviderCatalog {
    /// Parse the packaged versioned baseline without network/credential access.
    pub fn embedded() -> Result<Self, CoreError> {
        Self::try_from(EMBEDDED_MANIFEST)
    }
    /// Exact lookup; unknown custom IDs do not borrow another provider's policy.
    pub fn get(&self, id: &ApiProviderId) -> Option<&ProviderDefinition> {
        self.providers.get(id)
    }
    /// Credential-free baseline projection for synchronous editor metadata readers.
    pub fn snapshot(&self) -> Value {
        json!({"schema_version":1,"source_date":self.source_date,"revision":self.revision,
            "formats":self.formats,"providers":self.providers.values().collect::<Vec<_>>()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packaged_manifest_decodes() -> Result<(), serde_json::Error> {
        let _: Manifest = serde_json::from_str(EMBEDDED_MANIFEST)?;
        Ok(())
    }
}
