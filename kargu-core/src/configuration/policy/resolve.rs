//! Endpoint, selection and auth precedence are centralized here.

use super::{default_provider, domain::*, environment};
use crate::{
    api::ModelId,
    configuration::domain::ConfigText,
    error::CoreError,
    providers::{ApiEndpoint, ProviderCatalog},
};
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[derive(serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum CredentialSource {
    Global,
    Configuration,
    Environment,
    Keyless,
    Interop,
}

fn nonempty(value: Option<&ConfigText>) -> Option<&ConfigText> {
    value.filter(|value| !value.as_str().is_empty())
}

// A preview may describe an incomplete/invalid configuration.  Only a consumed
// ReadyProfile can cross the connection boundary; JSON is never domain state.
pub(super) struct Profile {
    provider: crate::providers::ApiProviderId,
    model: Option<ConfigText>,
    endpoint: Option<ConfigText>,
    checked_endpoint: Option<ApiEndpoint>,
    credential: Credential,
    source: CredentialSource,
    missing: BTreeSet<EnvironmentVariable>,
    authenticated: bool,
    keyless: bool,
    configured_model: Option<ConfigText>,
    models: Vec<ConfigText>,
    local: bool,
}
enum Credential {
    Direct(ConfigText),
    Keyless,
    Interop,
}
pub(super) struct ReadyProfile(Profile);
impl TryFrom<Profile> for ReadyProfile {
    type Error = CoreError;
    fn try_from(profile: Profile) -> Result<Self, Self::Error> {
        if profile.checked_endpoint.is_none() {
            return Err(CoreError::InvalidValue {
                field: "configuration_endpoint",
            });
        }
        if let Some(model) = &profile.model {
            // Empty is an explicit catalog target, not an API model identity.
            if !model.as_str().is_empty() {
                ModelId::try_from(model.as_str().to_owned()).map_err(|_| {
                    CoreError::InvalidValue {
                        field: "configuration_model",
                    }
                })?;
            }
        }
        Ok(Self(profile))
    }
}
impl ReadyProfile {
    pub(super) fn into_editor_value(self) -> Value {
        self.0.into_editor_value()
    }
}
impl Profile {
    pub(super) fn authenticated(&self) -> bool {
        self.authenticated
    }
    pub(super) fn into_editor_value(self) -> Value {
        let credential = match self.credential {
            Credential::Direct(secret) => json!({"kind":"direct","secret":secret.editor_value()}),
            Credential::Keyless => json!({"kind":"keyless"}),
            Credential::Interop => json!({"kind":"interop"}),
        };
        json!({"provider":self.provider,"model":self.model.as_ref().map(ConfigText::editor_value),
            "endpoint":self.endpoint.as_ref().map(ConfigText::editor_value),
            "host":self.checked_endpoint.as_ref().and_then(|endpoint|endpoint.as_url().host_str()),
            "credential":credential,"credential_source":self.source,"missing_environment":self.missing,
            "authenticated":self.authenticated,"keyless":self.keyless,
            "configured_model":self.configured_model.as_ref().map(ConfigText::editor_value),
            "models":self.models.iter().map(ConfigText::editor_value).collect::<Vec<_>>(),"local":self.local})
    }
}

pub(super) fn target(
    config: &ConfigurationDocument,
    context: &PolicyContext,
    input: TargetInput,
    catalog: &ProviderCatalog,
) -> Result<ReadyProfile, CoreError> {
    profile(config, context, input, catalog)?.try_into()
}

pub(super) fn profile(
    config: &ConfigurationDocument,
    context: &PolicyContext,
    input: TargetInput,
    catalog: &ProviderCatalog,
) -> Result<Profile, CoreError> {
    let selected_provider = input
        .selection
        .as_ref()
        .map(|selection| selection.provider.as_ref())
        .unwrap_or(context.selected_provider.as_ref());
    let selected_model = input
        .selection
        .as_ref()
        .map(|selection| selection.model.as_ref())
        .unwrap_or(context.selected_model.as_ref());
    let active = default_provider(config, selected_provider)?;
    let provider = input.provider.unwrap_or_else(|| active.clone());
    let fields = config.provider(&provider);
    let registered = context.registry.get(&provider);
    let baseline = catalog.get(&provider);
    let baseline_api = baseline
        .map(|definition| ConfigText::try_from(definition.endpoint_text().to_owned()))
        .transpose()
        .map_err(|_| CoreError::Limit)?;
    let endpoint = nonempty(fields.and_then(|fields| fields.api.as_ref()))
        .or_else(|| nonempty(registered.and_then(|entry| entry.api.as_ref())))
        .or_else(|| nonempty(baseline_api.as_ref()))
        .or_else(|| nonempty(context.api_base.as_ref()));
    let checked =
        endpoint.and_then(|endpoint| ApiEndpoint::try_from(endpoint.as_str().to_owned()).ok());
    let model = input
        .model
        .as_ref()
        .or_else(|| nonempty(selected_model))
        .or_else(|| {
            if selected_provider.is_none() {
                nonempty(config.model.as_ref())
            } else {
                None
            }
        })
        .or_else(|| nonempty(fields.and_then(|fields| fields.model.as_ref())));
    let raw = fields.and_then(|fields| fields.apikey.as_ref());
    let mut missing = BTreeSet::new();
    let expanded = raw
        .map(|raw| environment::expand(raw, &context.environment, &mut missing))
        .transpose()?
        .flatten();
    let mut env_names = Vec::new();
    if let Some(registered) = registered {
        env_names.extend(registered.env.iter().cloned());
    } else if let Some(baseline) = baseline {
        for name in baseline.environment() {
            env_names.push(EnvironmentVariable::try_from(name.to_owned())?);
        }
    }
    let env_key = env_names
        .iter()
        .find_map(|name| context.environment.get(name));
    let explicit_keyless = raw.is_some_and(|raw| raw.as_str().is_empty());
    let metadata_keyless = registered
        .map(|entry| entry.keyless)
        .unwrap_or_else(|| baseline.is_some_and(|entry| entry.keyless()));
    let global = nonempty(if provider == active {
        context.api_key.as_ref()
    } else {
        None
    });
    let configured = nonempty(expanded.as_ref());
    let (source, direct) = if global.is_some() {
        (CredentialSource::Global, global)
    } else if configured.is_some() {
        (CredentialSource::Configuration, configured)
    } else if explicit_keyless {
        (CredentialSource::Keyless, None)
    } else if env_key.is_some() {
        (CredentialSource::Environment, env_key)
    } else if metadata_keyless {
        (CredentialSource::Keyless, None)
    } else {
        (CredentialSource::Interop, None)
    };
    let credential = match direct {
        Some(secret) => Credential::Direct(secret.clone()),
        None if explicit_keyless || metadata_keyless => Credential::Keyless,
        None => Credential::Interop,
    };
    let authenticated = explicit_keyless
        || metadata_keyless
        || direct.is_some_and(|secret| {
            let trimmed = secret.as_str().trim();
            !trimmed.is_empty() && !trimmed.ends_with("...")
        });
    let models = fields
        .and_then(|fields| fields.models.as_ref())
        .filter(|models| !models.is_empty())
        .or_else(|| registered.map(|entry| &entry.models));
    Ok(Profile {
        provider,
        model: model.cloned(),
        endpoint: endpoint.cloned(),
        checked_endpoint: checked,
        credential,
        source,
        missing,
        authenticated,
        keyless: explicit_keyless || metadata_keyless,
        configured_model: nonempty(fields.and_then(|fields| fields.model.as_ref())).cloned(),
        models: models.cloned().unwrap_or_default(),
        local: registered
            .map(|entry| entry.local)
            .unwrap_or_else(|| baseline.is_some_and(|entry| entry.local())),
    })
}
