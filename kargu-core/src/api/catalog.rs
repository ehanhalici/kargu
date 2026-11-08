//! Native remote model catalog HTTP fetcher and parser.
//!
//! Rust Core owns remote catalog fetching via `reqwest`, JSON parsing,
//! and reasoning capability extraction.

use crate::{
    error::CoreError,
    models::{
        catalog::ModelCatalog,
        metadata::{EffortSpecs, ModelFields, RawMetadata},
        store::ModelSummaryDto,
    },
};
use std::time::Duration;

/// Fetch error for remote model catalog.
#[derive(Debug, thiserror::Error)]
pub enum CatalogFetchError {
    /// Network or connection failure.
    #[error("Catalog network connection failed")]
    Connection,
    /// Request timed out.
    #[error("Catalog request timed out")]
    Timeout,
    /// HTTP error status returned by provider.
    #[error("Catalog HTTP error: {status}")]
    Http {
        /// HTTP status code.
        status: u16,
    },
    /// Invalid catalog JSON or shape.
    #[error("Invalid catalog response shape")]
    Shape,
    /// Capacity limit exceeded.
    #[error("Catalog limit exceeded")]
    Limit,
}

impl From<CatalogFetchError> for CoreError {
    fn from(err: CatalogFetchError) -> Self {
        match err {
            CatalogFetchError::Connection => CoreError::Unavailable,
            CatalogFetchError::Timeout => CoreError::Deadline,
            CatalogFetchError::Http { .. } => CoreError::Unavailable,
            CatalogFetchError::Shape => CoreError::InvalidValue {
                field: "catalog_shape",
            },
            CatalogFetchError::Limit => CoreError::Limit,
        }
    }
}

/// Asynchronously fetch the remote model catalog for a provider and return parsed model summaries.
pub async fn fetch_remote_models(
    url: &str,
    auth_token: Option<&str>,
    extra_headers: &[(String, String)],
    specs: &EffortSpecs,
    timeout_duration: Duration,
) -> Result<(ModelCatalog, Vec<ModelSummaryDto>), CatalogFetchError> {
    let timeout_ms =
        u64::try_from(timeout_duration.as_millis()).map_err(|_| CatalogFetchError::Timeout)?;
    let mut headers = serde_json::Map::new();
    for (name, value) in extra_headers {
        if headers
            .insert(name.clone(), serde_json::json!(value))
            .is_some()
        {
            return Err(CatalogFetchError::Shape);
        }
    }
    let request: super::HttpRequest = serde_json::from_value(serde_json::json!({
        "url": url, "method": "get", "headers": headers, "stream": false,
        "response_profile": "model_catalog",
        "auth": {"key": auth_token},
        "timeouts": {"connect_ms": 5000, "first_byte_ms": timeout_ms, "deadline_ms": timeout_ms},
    }))
    .map_err(|_| CatalogFetchError::Shape)?;
    let snapshot = super::execute(
        request,
        |_| async { Ok(()) },
        tokio_util::sync::CancellationToken::new(),
    )
    .await
    .map_err(|error| match error {
        super::ApiError::Deadline
        | super::ApiError::FirstByteTimeout
        | super::ApiError::IdleTimeout => CatalogFetchError::Timeout,
        super::ApiError::Http { status, .. } => CatalogFetchError::Http {
            status: status.as_u16(),
        },
        super::ApiError::Limit => CatalogFetchError::Limit,
        super::ApiError::InvalidRequest | super::ApiError::Protocol => CatalogFetchError::Shape,
        _ => CatalogFetchError::Connection,
    })?;
    let source = snapshot.to_string();
    let catalog = ModelCatalog::try_from(source.as_str()).map_err(|_| CatalogFetchError::Shape)?;

    let summaries = summaries(&catalog, specs);
    Ok((catalog, summaries))
}

pub(crate) fn summaries(catalog: &ModelCatalog, specs: &EffortSpecs) -> Vec<ModelSummaryDto> {
    catalog
        .records()
        .filter_map(|(model_id, source)| summary(model_id.as_str(), source.get(), specs))
        .collect()
}

/// One model's display summary; records whose metadata does not parse are skipped.
fn summary(model_id: &str, source: &str, specs: &EffortSpecs) -> Option<ModelSummaryDto> {
    let raw = RawMetadata::try_from(source).ok()?;
    let fields = ModelFields::from_raw(&raw, specs);
    let display = fields.display_snapshot();
    let efforts = display
        .get("reasoning-efforts")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    let price_label = display
        .get("price-label")
        .and_then(|v| v.as_str().map(String::from));
    let free = display
        .get("free")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let vision = display
        .get("vision")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let context_window = display.get("context-window").and_then(|v| v.as_u64());
    let max_output = display.get("max-output").and_then(|v| v.as_u64());
    Some(ModelSummaryDto {
        id: model_id.to_owned(),
        context_window,
        max_output,
        reasoning_efforts: efforts,
        price_label,
        free,
        vision,
        supports_tools: fields.allows_tools(),
        supports_reasoning: fields.allows_reasoning(),
    })
}
