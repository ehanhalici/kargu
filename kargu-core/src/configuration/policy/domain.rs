//! Normalized config and editor captures. Secret-bearing types are not printable.

use crate::{configuration::domain::ConfigText, error::CoreError, providers::ApiProviderId};
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ProviderFields {
    pub(super) api: Option<ConfigText>,
    pub(super) apikey: Option<ConfigText>,
    pub(super) model: Option<ConfigText>,
    pub(super) models: Option<Vec<ConfigText>>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ConfiguredProvider {
    pub(super) name: ApiProviderId,
    pub(super) data: ProviderFields,
}

/// Closed normalized parser output. Raw TOML never enters this DTO.
#[derive(Clone, Deserialize)]
#[serde(try_from = "DocumentDto")]
pub struct ConfigurationDocument {
    pub(super) provider: Option<ApiProviderId>,
    pub(super) model: Option<ConfigText>,
    pub(super) review_mode: Option<ReviewMode>,
    pub(super) providers: Vec<ConfiguredProvider>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DocumentDto {
    provider: Option<ApiProviderId>,
    model: Option<ConfigText>,
    #[serde(rename = "review-mode")]
    review_mode: Option<ReviewMode>,
    providers: Vec<ConfiguredProvider>,
}
#[derive(Clone, Copy, Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum ReviewMode {
    Auto,
    Async,
    Blocking,
}
impl TryFrom<DocumentDto> for ConfigurationDocument {
    type Error = CoreError;
    fn try_from(value: DocumentDto) -> Result<Self, Self::Error> {
        let mut names = std::collections::BTreeSet::new();
        let mut bytes = 0_usize;
        if value.providers.len() > 512 {
            return Err(CoreError::Limit);
        }
        for provider in &value.providers {
            if !names.insert(provider.name.clone()) {
                return Err(CoreError::InvalidValue {
                    field: "configuration_provider",
                });
            }
            for text in [
                &provider.data.api,
                &provider.data.apikey,
                &provider.data.model,
            ]
            .into_iter()
            .flatten()
            {
                bytes = bytes.saturating_add(text.as_str().len());
            }
            if let Some(models) = &provider.data.models {
                if models.len() > 4096 {
                    return Err(CoreError::Limit);
                }
                bytes = models.iter().fold(bytes, |bytes, model| {
                    bytes.saturating_add(model.as_str().len())
                });
            }
        }
        if bytes > 512 * 1024 {
            return Err(CoreError::Limit);
        }
        Ok(Self {
            provider: value.provider,
            model: value.model,
            review_mode: value.review_mode,
            providers: value.providers,
        })
    }
}
impl ConfigurationDocument {
    pub(super) fn editor_value(&self) -> serde_json::Value {
        use serde_json::{Map, Value, json};
        let providers = self
            .providers
            .iter()
            .map(|provider| {
                let mut data = Map::new();
                for (name, value) in [
                    ("api", &provider.data.api),
                    ("apikey", &provider.data.apikey),
                    ("model", &provider.data.model),
                ] {
                    if let Some(value) = value {
                        data.insert(name.into(), value.editor_value());
                    }
                }
                if let Some(models) = &provider.data.models {
                    data.insert(
                        "models".into(),
                        json!(
                            models
                                .iter()
                                .map(ConfigText::editor_value)
                                .collect::<Vec<_>>()
                        ),
                    );
                }
                json!({"name":provider.name,"data":data})
            })
            .collect::<Vec<_>>();
        json!({"provider":self.provider,"model":self.model.as_ref().map(ConfigText::editor_value), "review-mode":self.review_mode,"providers":Value::Array(providers)})
    }
    pub(super) fn empty() -> Self {
        Self {
            provider: None,
            model: None,
            review_mode: None,
            providers: Vec::new(),
        }
    }
    pub(super) fn provider(&self, id: &ApiProviderId) -> Option<&ProviderFields> {
        self.providers
            .iter()
            .find(|provider| &provider.name == id)
            .map(|provider| &provider.data)
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq, Ord, PartialOrd, serde::Serialize)]
#[serde(try_from = "String")]
pub(super) struct EnvironmentVariable(String);
impl TryFrom<String> for EnvironmentVariable {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let mut chars = value.chars();
        if value.len() > 256
            || !chars
                .next()
                .is_some_and(|ch| ch.is_alphanumeric() || ch == '_')
            || !chars.all(|ch| ch.is_alphanumeric() || ch == '_')
        {
            return Err(CoreError::InvalidValue {
                field: "configuration_environment_name",
            });
        }
        Ok(Self(value))
    }
}
impl EnvironmentVariable {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
    pub(super) fn parse_reference(rest: &str) -> Option<(Self, &str)> {
        if !rest
            .chars()
            .next()
            .is_some_and(|ch| ch.is_alphabetic() || ch == '_')
        {
            return None;
        }
        for (offset, ch) in rest.char_indices() {
            if offset > 256 {
                return None;
            }
            if ch == '}' {
                return Some((
                    Self(rest.get(..offset)?.to_owned()),
                    rest.get(offset.saturating_add(1)..)?,
                ));
            }
            if !(ch.is_alphanumeric() || ch == '_') {
                return None;
            }
        }
        None
    }
}

#[derive(Deserialize)]
#[serde(try_from = "BTreeMap<EnvironmentVariable, Option<ConfigText>>")]
/// Bounded captured values for only the variable names requested by native policy.
pub struct EnvironmentSnapshot(BTreeMap<EnvironmentVariable, Option<ConfigText>>);
impl TryFrom<BTreeMap<EnvironmentVariable, Option<ConfigText>>> for EnvironmentSnapshot {
    type Error = CoreError;
    fn try_from(
        values: BTreeMap<EnvironmentVariable, Option<ConfigText>>,
    ) -> Result<Self, Self::Error> {
        let bytes = values.iter().fold(0_usize, |bytes, (name, value)| {
            bytes.saturating_add(name.0.len()).saturating_add(
                value
                    .as_ref()
                    .map(|value| value.as_str().len())
                    .unwrap_or_default(),
            )
        });
        if values.len() > 2048 || bytes > 256 * 1024 {
            return Err(CoreError::Limit);
        }
        Ok(Self(values))
    }
}
impl EnvironmentSnapshot {
    pub(super) fn entries(&self) -> &BTreeMap<EnvironmentVariable, Option<ConfigText>> {
        &self.0
    }
    pub(super) fn get(&self, name: &EnvironmentVariable) -> Option<&ConfigText> {
        self.0
            .get(name)
            .and_then(Option::as_ref)
            .filter(|value| !value.as_str().is_empty())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RegistryEntry {
    pub(super) id: ApiProviderId,
    pub(super) api: Option<ConfigText>,
    #[serde(default)]
    pub(super) models: Vec<ConfigText>,
    #[serde(default)]
    pub(super) env: Vec<EnvironmentVariable>,
    #[serde(default)]
    pub(super) keyless: bool,
    #[serde(default)]
    pub(super) local: bool,
}
#[derive(Deserialize)]
#[serde(try_from = "Vec<RegistryEntry>")]
/// Bounded editor registry projection, independent of the native catalog baseline.
pub struct RegistrySnapshot(Vec<RegistryEntry>);
impl TryFrom<Vec<RegistryEntry>> for RegistrySnapshot {
    type Error = CoreError;
    fn try_from(entries: Vec<RegistryEntry>) -> Result<Self, Self::Error> {
        let mut ids = std::collections::BTreeSet::new();
        let mut bytes = 0_usize;
        if entries.len() > 512 {
            return Err(CoreError::Limit);
        }
        for entry in &entries {
            if !ids.insert(entry.id.clone()) || entry.env.len() > 16 || entry.models.len() > 4096 {
                return Err(CoreError::InvalidValue {
                    field: "configuration_registry",
                });
            }
            bytes = bytes.saturating_add(
                entry
                    .api
                    .as_ref()
                    .map(|api| api.as_str().len())
                    .unwrap_or_default(),
            );
            bytes = entry.models.iter().fold(bytes, |bytes, model| {
                bytes.saturating_add(model.as_str().len())
            });
        }
        if bytes > 512 * 1024 {
            return Err(CoreError::Limit);
        }
        Ok(Self(entries))
    }
}
impl RegistrySnapshot {
    pub(super) fn entries(&self) -> &[RegistryEntry] {
        &self.0
    }
    pub(super) fn get(&self, id: &ApiProviderId) -> Option<&RegistryEntry> {
        self.0.iter().find(|entry| &entry.id == id)
    }
}

/// Captured editor options are inputs, never a second precedence implementation.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyContext {
    pub(super) api_base: Option<ConfigText>,
    pub(super) api_key: Option<ConfigText>,
    pub(super) selected_provider: Option<ApiProviderId>,
    pub(super) selected_model: Option<ConfigText>,
    pub(super) environment: EnvironmentSnapshot,
    pub(super) registry: RegistrySnapshot,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
/// Explicit request overrides, distinct from session selection intent.
pub struct TargetInput {
    pub(super) provider: Option<ApiProviderId>,
    pub(super) model: Option<ConfigText>,
    pub(super) selection: Option<SelectionInput>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SelectionInput {
    pub(super) provider: Option<ApiProviderId>,
    pub(super) model: Option<ConfigText>,
}
