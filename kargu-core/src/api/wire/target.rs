//! A static chat path cannot replace the captured origin or alter its query.

use crate::{api::ApiError, providers::ApiEndpoint};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(super) struct ChatPath(String);

impl Default for ChatPath {
    fn default() -> Self {
        Self("/chat/completions".to_owned())
    }
}

impl TryFrom<String> for ChatPath {
    type Error = ApiError;

    fn try_from(value: String) -> Result<Self, ApiError> {
        if value.len() > 1024
            || !value.starts_with('/')
            || value.contains("//")
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte))
            || value
                .split('/')
                .any(|segment| matches!(segment, "." | ".."))
        {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(value))
    }
}

impl ChatPath {
    pub(super) fn append_to(&self, base: ApiEndpoint) -> Result<ApiEndpoint, ApiError> {
        let mut url = base.as_url().clone();
        let path = format!("{}{}", url.path().trim_end_matches('/'), self.0);
        url.set_path(&path);
        // The composition is a new value: enforce the endpoint's total bound
        // before authority/continuation capture, admission, retries or any IO.
        ApiEndpoint::try_from(String::from(url)).map_err(|_| ApiError::InvalidRequest)
    }
}
