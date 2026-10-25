//! Internal equality key for captured upstream authority; never a public identity.

use super::ApiError;
use crate::providers::{ApiEndpoint, ApiProviderId};
use reqwest::header::HeaderMap;
use sha2::{Digest, Sha256};

/// Not Debug/Serialize: even a credential fingerprint does not belong in UI/logs.
/// Model/wire revision is deliberately not a provider circuit namespace.
#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ApiAuthority([u8; 32]);
impl ApiAuthority {
    pub(super) fn capture(
        endpoint: &ApiEndpoint,
        provider: Option<&ApiProviderId>,
        headers: &HeaderMap,
    ) -> Result<Self, ApiError> {
        let mut digest = Sha256::new();
        digest.update(b"kargu-api-authority-v1\0");
        component(&mut digest, endpoint.as_url().as_str().as_bytes())?;
        component(
            &mut digest,
            provider.map_or(b"", |id| id.as_str().as_bytes()),
        )?;
        let mut sorted: Vec<_> = headers.iter().collect();
        sorted.sort_unstable_by(|(left, _), (right, _)| left.as_str().cmp(right.as_str()));
        for (name, value) in sorted {
            component(&mut digest, name.as_str().as_bytes())?;
            component(&mut digest, value.as_bytes())?;
        }
        Ok(Self(digest.finalize().into()))
    }
}
fn component(digest: &mut Sha256, bytes: &[u8]) -> Result<(), ApiError> {
    digest.update(
        u64::try_from(bytes.len())
            .map_err(|_| ApiError::Limit)?
            .to_le_bytes(),
    );
    digest.update(bytes);
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::api::HttpRequest;
    use serde_json::json;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    #[test]
    fn header_spelling_order_and_model_are_not_authority_but_provider_auth_and_target_are()
    -> TestResult {
        let base = json!({"method":"post","url":"https://fixture.invalid/Target","provider":"fixture",
            "headers":{"Authorization":"Bearer synthetic","X-Tenant":"a"},"stream":false,
            "body":"{\"model\":\"one\"}","timeouts":{"connect_ms":500,"first_byte_ms":500,"idle_ms":null,"deadline_ms":1000}});
        let capture: HttpRequest = serde_json::from_value(base.clone())?;
        let mut spelling = base.clone();
        spelling["headers"] = json!({"x-tenant":"a","authorization":"Bearer synthetic"});
        spelling["body"] = json!("{\"model\":\"two\"}");
        let same: HttpRequest = serde_json::from_value(spelling)?;
        assert!(capture.authority == same.authority);
        for (field, value) in [
            ("url", "https://fixture.invalid/target"),
            ("provider", "other"),
        ] {
            let mut changed = base.clone();
            changed[field] = json!(value);
            let other: HttpRequest = serde_json::from_value(changed)?;
            assert!(capture.authority != other.authority);
        }
        for header in ["Authorization", "X-Tenant"] {
            let mut changed = base.clone();
            changed["headers"][header] = json!("changed-synthetic");
            let other: HttpRequest = serde_json::from_value(changed)?;
            assert!(capture.authority != other.authority);
        }
        Ok(())
    }
}
