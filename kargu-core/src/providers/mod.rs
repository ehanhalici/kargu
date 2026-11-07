//! Versioned embedded API provider catalog and credential-free UI snapshots.

pub mod catalog_target;
mod domain;
use domain::SourceDate;
pub use domain::{
    ApiEndpoint, ApiProviderId, CatalogEndpoint, CatalogOffset, EnvironmentName, ProviderName,
    WireFamily,
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
    pub(crate) fn request_policy(&self) -> Option<&Value> {
        self.request.as_ref()
    }
    /// Configuration policy reads names, never process environment values.
    pub fn environment(&self) -> impl Iterator<Item = &str> {
        self.env.iter().map(EnvironmentName::as_str)
    }
    /// Literal catalog endpoint spelling; policy validates the selected target.
    pub fn endpoint_text(&self) -> &str {
        self.api.as_str()
    }
    /// Declared keyless authentication profile.
    pub fn keyless(&self) -> bool {
        self.keyless
    }
    /// Local runner annotation, independent of authentication.
    pub fn local(&self) -> bool {
        self.local
    }
    /// Canonical API namespace, never an installed-application backend ID.
    pub fn id(&self) -> &ApiProviderId {
        &self.id
    }
    /// Display name of the provider.
    pub fn name(&self) -> &ProviderName {
        &self.name
    }
    /// Implemented wire, or explicit unsupported metadata.
    pub fn family(&self) -> Option<WireFamily> {
        self.format
    }
    /// Default endpoint before explicit user overrides.
    pub fn endpoint(&self) -> &CatalogEndpoint {
        &self.api
    }
    /// Default remote models endpoint for catalog refresh.
    pub fn models_endpoint(&self) -> &CatalogEndpoint {
        &self.models_api
    }
    pub(crate) fn catalog_headers(&self) -> Value {
        json!(self.extra_headers)
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
    /// Bounded immutable baseline for configuration policy capture.
    pub fn definitions(&self) -> impl Iterator<Item = &ProviderDefinition> {
        self.providers.values()
    }
    /// Parse the packaged versioned baseline without network/credential access.
    pub fn embedded() -> Result<Self, CoreError> {
        Self::try_from(EMBEDDED_MANIFEST)
    }
    /// Exact lookup; unknown custom IDs do not borrow another provider's policy.
    pub fn get(&self, id: &ApiProviderId) -> Option<&ProviderDefinition> {
        self.providers.get(id)
    }
    /// Extract reasoning effort specifications declared for a provider.
    pub fn effort_specs(&self, provider: &ApiProviderId) -> crate::models::metadata::EffortSpecs {
        let Some(p) = self.get(provider) else {
            return crate::models::metadata::EffortSpecs::default();
        };
        let Some(family) = p.family() else {
            return crate::models::metadata::EffortSpecs::default();
        };
        let Some(format_val) = self.formats.get(family.as_str()) else {
            return crate::models::metadata::EffortSpecs::default();
        };
        let Some(models_val) = format_val.get("models") else {
            return crate::models::metadata::EffortSpecs::default();
        };
        let Some(efforts_val) = models_val.get("reasoning-efforts") else {
            return crate::models::metadata::EffortSpecs::default();
        };
        serde_json::from_value(efforts_val.clone()).unwrap_or_default()
    }
    pub(crate) fn wire_value(&self, provider: &ApiProviderId) -> Option<&Value> {
        self.get(provider)
            .and_then(ProviderDefinition::family)
            .and_then(|family| self.formats.get(family.as_str()))
    }
    /// Resolve model discovery from native metadata and a configuration endpoint.
    pub(crate) fn catalog_connection(
        &self,
        provider: &ApiProviderId,
        api_base: &str,
    ) -> Result<(ApiEndpoint, catalog_target::CatalogAuthentication), CoreError> {
        let definition = self.get(provider);
        let input: catalog_target::CatalogConnectionInput = serde_json::from_value(json!({
            "api_base": api_base,
            "default_api": definition.map(|entry| &entry.api),
            "models_api": definition.map(|entry| &entry.models_api),
            "models_auth": definition.and_then(|entry| entry.models_auth.as_ref()),
            "native_models": self.wire_value(provider).and_then(|wire| wire.get("native-models")),
        }))
        .map_err(|_| CoreError::InvalidValue {
            field: "catalog_target",
        })?;
        input.resolve()
    }
    /// Credential-free baseline projection for synchronous editor metadata readers.
    pub fn snapshot(&self) -> Value {
        json!({"schema_version":1,"source_date":self.source_date,"revision":self.revision,
            "formats":self.formats,"providers":self.providers.values().collect::<Vec<_>>()})
    }
    /// Frame-bounded UTF-8 slice of the credential-free catalog snapshot.
    pub fn page(
        &self,
        offset: CatalogOffset,
        frame: crate::domain::ByteLimit,
    ) -> Result<Value, CoreError> {
        let text =
            serde_json::to_string(&self.snapshot()).map_err(|_| CoreError::InvalidValue {
                field: "ProviderManifest",
            })?;
        if text.len() > crate::constants::limits::PROVIDER_CATALOG_BYTES {
            return Err(CoreError::Limit);
        }
        let start = offset.as_usize();
        if start > text.len() || !text.is_char_boundary(start) {
            return Err(CoreError::InvalidValue {
                field: "CatalogOffset",
            });
        }
        let budget = frame.as_usize().saturating_sub(128) / 6;
        if budget < 4 {
            return Err(CoreError::Limit);
        }
        let mut end = start.saturating_add(budget).min(text.len());
        while end > start && !text.is_char_boundary(end) {
            end = end.checked_sub(1).ok_or(CoreError::Limit)?;
        }
        Ok(json!({
            "text": &text[start..end],
            "offset": start,
            "next_offset": end,
            "complete": end == text.len(),
        }))
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
