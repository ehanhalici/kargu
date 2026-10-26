//! Endpoint, selection and auth precedence are centralized here.

use super::{default_provider, domain::*, environment};
use crate::{
    configuration::domain::ConfigText,
    error::CoreError,
    providers::{ApiEndpoint, ProviderCatalog},
};
use serde_json::{Value, json};
use std::collections::BTreeSet;

fn nonempty(value: Option<&ConfigText>) -> Option<&ConfigText> {
    value.filter(|value| !value.as_str().is_empty())
}

pub(super) fn target(
    config: &ConfigurationDocument,
    context: &PolicyContext,
    input: TargetInput,
    catalog: &ProviderCatalog,
) -> Result<Value, CoreError> {
    let value = profile(config, context, input, catalog)?;
    let endpoint =
        value
            .get("endpoint")
            .and_then(Value::as_str)
            .ok_or(CoreError::InvalidValue {
                field: "configuration_endpoint",
            })?;
    ApiEndpoint::try_from(endpoint.to_owned())?;
    Ok(value)
}

pub(super) fn profile(
    config: &ConfigurationDocument,
    context: &PolicyContext,
    input: TargetInput,
    catalog: &ProviderCatalog,
) -> Result<Value, CoreError> {
    let active = default_provider(config, context)?;
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
    let model = nonempty(input.model.as_ref())
        .or_else(|| nonempty(context.selected_model.as_ref()))
        .or_else(|| {
            if context.selected_provider.is_none() {
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
    let direct = nonempty(if provider == active {
        context.api_key.as_ref()
    } else {
        None
    })
    .or_else(|| nonempty(expanded.as_ref()))
    .or(if explicit_keyless { None } else { env_key });
    let credential = match direct {
        Some(secret) => json!({"kind":"direct","secret":secret.editor_value()}),
        None if explicit_keyless || metadata_keyless => json!({"kind":"keyless"}),
        None => json!({"kind":"interop"}),
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
    Ok(
        json!({"provider":provider,"model":model.map(ConfigText::editor_value),
        "endpoint":endpoint.map(ConfigText::editor_value),"host":checked.as_ref().and_then(|endpoint|endpoint.as_url().host_str()),
        "credential":credential,"missing_environment":missing,
        "authenticated":authenticated,"keyless":explicit_keyless || metadata_keyless,
        "configured_model":fields.and_then(|fields|fields.model.as_ref()).map(ConfigText::editor_value),
        "models":models.map(|models| models.iter().map(ConfigText::editor_value).collect::<Vec<_>>()).unwrap_or_default(),
        "local":registered.map(|entry|entry.local).unwrap_or_else(||baseline.is_some_and(|entry|entry.local()))}),
    )
}
