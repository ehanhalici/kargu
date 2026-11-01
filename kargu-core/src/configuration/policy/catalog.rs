//! Native configuration-to-discovery capture; no editor target/auth orchestration.

use super::{ConfigurationDocument, PolicyContext, TargetInput, resolve};
use crate::{
    api::HttpRequest,
    error::CoreError,
    providers::{ApiProviderId, ProviderCatalog},
};

/// Capture one model-list request from native configuration and provider policy.
/// The returned request owns its endpoint, wire and credentials. Public catalog
/// endpoints omit credentials; private discovery without a ready credential is
/// explicitly unavailable. Auth-source interop must complete before admission.
/// This function performs no IO and never exposes secrets in a UI DTO.
pub fn prepare_catalog_request(
    document: &ConfigurationDocument,
    context: &PolicyContext,
    provider: ApiProviderId,
    session: &crate::domain::SessionId,
    catalog: &ProviderCatalog,
) -> Result<HttpRequest, CoreError> {
    resolve::profile(
        document,
        context,
        TargetInput {
            provider: Some(provider),
            model: None,
            selection: None,
        },
        catalog,
    )?
    .into_catalog_request(catalog, session)
}
