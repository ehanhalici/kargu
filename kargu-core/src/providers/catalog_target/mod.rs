//! Pure catalog target projection. It performs no IO and grants no execution lease.

mod domain;
pub use domain::ConfigurationRevision;

use super::{ApiEndpoint, ApiProviderId, CatalogEndpoint};
use crate::error::CoreError;
use domain::{CapturedApiBase, ModelsAuth, NativeModels};
use serde::{Deserialize, Serialize};

/// Captured registry/config facts, parsed once before target selection.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogTargetInput {
    provider: ApiProviderId,
    configuration_revision: ConfigurationRevision,
    api_base: CapturedApiBase,
    default_api: Option<CatalogEndpoint>,
    models_api: Option<CatalogEndpoint>,
    models_auth: Option<ModelsAuth>,
    native_models: Option<NativeModels>,
}

/// Public skips provider credential lookup; Provider retains the existing port.
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogAuthentication {
    /// Only the explicitly declared dedicated endpoint without a base override.
    Public,
    /// Resolve provider credentials, including explicitly configured keyless access.
    Provider,
}

/// Immutable target DTO, not an approval token or an execution capability.
#[derive(Serialize)]
pub struct CatalogTarget {
    provider: ApiProviderId,
    configuration_revision: ConfigurationRevision,
    url: ApiEndpoint,
    authentication: CatalogAuthentication,
}

impl CatalogTargetInput {
    /// Consume captured input without consulting mutable provider/config state.
    pub fn resolve(self) -> Result<CatalogTarget, CoreError> {
        let custom = self
            .default_api
            .as_ref()
            .is_some_and(|default| !self.api_base.matches_default(default));
        let dedicated = self.models_api.as_ref().filter(|_| !custom);
        let (url, authentication) = if let Some(endpoint) = dedicated {
            let url = ApiEndpoint::try_from(endpoint.as_str().to_owned())?;
            let authentication = match self.models_auth.unwrap_or_default() {
                ModelsAuth::None => CatalogAuthentication::Public,
                ModelsAuth::Required => CatalogAuthentication::Provider,
            };
            (url, authentication)
        } else {
            (self.derived(custom)?, CatalogAuthentication::Provider)
        };
        Ok(CatalogTarget {
            provider: self.provider,
            configuration_revision: self.configuration_revision,
            url,
            authentication,
        })
    }

    fn derived(&self, custom: bool) -> Result<ApiEndpoint, CoreError> {
        let mut url = self.api_base.endpoint().as_url().clone();
        let path = url.path().trim_end_matches('/');
        let native = self.native_models.as_ref().filter(|spec| {
            !spec
                .unless_suffix
                .as_ref()
                .is_some_and(|suffix| path.ends_with(suffix.as_str()))
        });
        let suffix = match (custom && path.ends_with("/models"), native) {
            (true, _) => "",
            (false, Some(spec)) => spec.path.as_str(),
            (false, None) if path.ends_with("/models") => "",
            (false, None) => "/models",
        };
        if !suffix.is_empty() {
            url.set_path(&format!("{path}{suffix}"));
        }
        ApiEndpoint::try_from(String::from(url))
    }
}
