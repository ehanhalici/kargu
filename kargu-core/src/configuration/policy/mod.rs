//! Native configuration selection and credential-source policy, with no IO.

mod domain;
mod environment;
mod resolve;
mod service;
use crate::{
    error::CoreError,
    providers::{ApiProviderId, ProviderCatalog},
};
pub use domain::{
    ConfigurationDocument, EnvironmentSnapshot, PolicyContext, RegistrySnapshot, TargetInput,
};
use serde_json::{Value, json};
pub(crate) use service::ConfigurationService;
use std::collections::BTreeSet;

/// Variable names requested from editor interop; no process environment lookup.
pub fn environment_names(
    config: &ConfigurationDocument,
    registry: &RegistrySnapshot,
    catalog: &ProviderCatalog,
) -> Result<Value, CoreError> {
    let mut names = BTreeSet::new();
    for provider in &config.providers {
        if let Some(key) = &provider.data.apikey {
            environment::names(key.as_str(), &mut names);
        }
    }
    for provider in registry.entries() {
        names.extend(provider.env.iter().cloned());
    }
    for provider in catalog.definitions() {
        for name in provider.environment() {
            names.insert(domain::EnvironmentVariable::try_from(name.to_owned())?);
        }
    }
    if names.len() > 2048 {
        return Err(CoreError::Limit);
    }
    Ok(json!(names))
}

/// Explicit private result; intentionally no Serialize or Debug implementation.
pub struct PolicyTarget(Value);
impl PolicyTarget {
    /// Private editor credential handoff. Callers must never log this projection.
    pub fn into_editor_value(self) -> Value {
        self.0
    }
}

/// Resolve a captured context without consulting mutable editor/native globals.
pub fn resolve(
    config: &ConfigurationDocument,
    context: &PolicyContext,
    input: TargetInput,
    catalog: &ProviderCatalog,
) -> Result<PolicyTarget, CoreError> {
    resolve::target(config, context, input, catalog).map(PolicyTarget)
}

pub(super) fn default_provider(
    config: &ConfigurationDocument,
    context: &PolicyContext,
) -> Result<ApiProviderId, CoreError> {
    context
        .selected_provider
        .as_ref()
        .or(config.provider.as_ref())
        .or_else(|| config.providers.first().map(|provider| &provider.name))
        .cloned()
        .map(Ok)
        .unwrap_or_else(|| ApiProviderId::try_from("default".to_owned()))
}
