//! Provider wire codecs. Canonical chat data crosses the editor boundary once.

mod domain;
mod request;
mod response;
use super::{ApiError, ModelId};
use crate::providers::{ApiEndpoint, ApiProviderId};
pub(super) use domain::OutputLimit;
pub use domain::WireSpec;
use serde_json::Value;
use sha2::{Digest, Sha256};

struct ContinuationScope(String);

/// A codec bound to provider namespace, exact endpoint, model and format revision.
pub struct WireCodec {
    spec: WireSpec,
    scope: ContinuationScope,
}

impl WireCodec {
    pub(super) fn tune(
        &self,
        payload: Value,
        tuning: &super::policy::RequestTuning,
    ) -> Result<Value, ApiError> {
        tuning.apply(payload, &self.spec.policy, self.spec.reasoning)
    }
    /// Encode only opaque continuation blocks from this same captured authority.
    pub fn encode(&self, mut payload: Value) -> Result<Value, ApiError> {
        if let Some(messages) = payload.get_mut("messages").and_then(Value::as_array_mut) {
            for message in messages {
                if let Some(message) = message.as_object_mut() {
                    let opaque = message.remove("_kargu_opaque_content");
                    if self.spec.request.is_some()
                        && let Some(opaque) = opaque
                        && opaque.get("scope").and_then(Value::as_str)
                            == Some(self.scope.0.as_str())
                        && let Some(blocks) = opaque.get("blocks").and_then(Value::as_array)
                    {
                        message.insert(
                            "_kargu_opaque_content".to_owned(),
                            Value::Array(blocks.clone()),
                        );
                    }
                }
            }
        }
        self.spec.encode(payload)
    }
    /// Normalize a response and retain provider-only continuation as opaque data.
    pub fn decode(&self, response: Value) -> Result<Value, ApiError> {
        let mut response = self.spec.decode(response)?;
        if let Some(choices) = response.get_mut("choices").and_then(Value::as_array_mut) {
            for choice in choices {
                if let Some(message) = choice.get_mut("message").and_then(Value::as_object_mut)
                    && let Some(opaque) = message.remove("_kargu_opaque_content")
                {
                    message.insert(
                        "_kargu_opaque_content".to_owned(),
                        serde_json::json!({"scope":self.scope.0,"blocks":opaque}),
                    );
                }
            }
        }
        Ok(response)
    }
    pub(super) fn streams(&self) -> bool {
        self.spec.stream
    }
}

impl WireSpec {
    /// Bind metadata before IO; a different model/provider/endpoint cannot borrow signatures.
    pub fn bind(
        self,
        endpoint: &ApiEndpoint,
        model: Option<&ModelId>,
        provider: Option<&ApiProviderId>,
    ) -> Result<WireCodec, ApiError> {
        let identity = serde_json::to_vec(&(
            endpoint.as_url().as_str(),
            model,
            provider,
            self.revision.0.as_str(),
        ))
        .map_err(|_| ApiError::InvalidRequest)?;
        Ok(WireCodec {
            spec: self,
            scope: ContinuationScope(format!("{:x}", Sha256::digest(identity))),
        })
    }
    /// Convert an owned canonical payload without modifying editor history.
    pub fn encode(&self, payload: Value) -> Result<Value, ApiError> {
        match self.request.as_ref() {
            Some(rules) => request::encode(payload, rules),
            None => Ok(payload),
        }
    }
    /// Convert only the captured response shape; never infer another provider.
    pub fn decode(&self, response: Value) -> Result<Value, ApiError> {
        match self.response.as_ref() {
            Some(rules) => response::decode(response, rules),
            None => Ok(response),
        }
    }
}
