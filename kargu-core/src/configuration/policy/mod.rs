//! Native configuration selection and credential-source policy, with no IO.
//!
//! Captured configuration and resolved targets are not diagnostic/serialization
//! surfaces.  Secrets leave only through the explicit private editor handoff.
//! ```compile_fail
//! fn print(value: kargu_core::configuration::policy::ConfigurationDocument) {
//!     println!("{value:?}");
//! }
//! ```
//! ```compile_fail
//! fn serialize(value: kargu_core::configuration::policy::ConfigurationDocument) {
//!     let _ = serde_json::to_string(&value);
//! }
//! ```
//! ```compile_fail
//! fn print(value: kargu_core::configuration::policy::PolicyTarget) {
//!     println!("{value:?}");
//! }
//! ```
//! ```compile_fail
//! fn serialize(value: kargu_core::configuration::policy::PolicyTarget) {
//!     let _ = serde_json::to_string(&value);
//! }
//! ```

mod domain;
mod environment;
mod identity;
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
pub struct PolicyTarget(resolve::ReadyProfile);
impl PolicyTarget {
    /// Private editor credential handoff. Callers must never log this projection.
    pub fn into_editor_value(self) -> Value {
        self.0.into_editor_value()
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
    selected: Option<&ApiProviderId>,
) -> Result<ApiProviderId, CoreError> {
    selected
        .or(config.provider.as_ref())
        .or_else(|| config.providers.first().map(|provider| &provider.name))
        .cloned()
        .map(Ok)
        .unwrap_or_else(|| ApiProviderId::try_from("default".to_owned()))
}
