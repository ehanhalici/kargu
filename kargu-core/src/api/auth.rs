//! Captured auth/header policy. Secrets are never catalog or diagnostic data.

use super::{ApiError, SecretString};
use reqwest::header::{CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue};
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};

#[derive(Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(super) enum AuthKind {
    #[default]
    Bearer,
    XApiKey,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Binding {
    Session,
    AppUrl,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BindingDto {
    binding: Binding,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum TemplateDto {
    Literal(SecretString),
    Bound(BindingDto),
}

#[derive(Deserialize)]
#[serde(try_from = "TemplateDto")]
enum HeaderTemplate {
    Literal(HeaderValue),
    Session,
    AppUrl,
}
impl TryFrom<TemplateDto> for HeaderTemplate {
    type Error = ApiError;
    fn try_from(value: TemplateDto) -> Result<Self, ApiError> {
        match value {
            TemplateDto::Literal(value) => Ok(Self::Literal(header_value(value.exposed())?)),
            TemplateDto::Bound(BindingDto {
                binding: Binding::Session,
            }) => Ok(Self::Session),
            TemplateDto::Bound(BindingDto {
                binding: Binding::AppUrl,
            }) => Ok(Self::AppUrl),
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(try_from = "BTreeMap<String, HeaderTemplate>")]
pub(super) struct HeaderTemplates(Vec<(HeaderName, HeaderTemplate)>);
impl TryFrom<BTreeMap<String, HeaderTemplate>> for HeaderTemplates {
    type Error = ApiError;
    fn try_from(value: BTreeMap<String, HeaderTemplate>) -> Result<Self, ApiError> {
        if value.len() > 64 {
            return Err(ApiError::Limit);
        }
        let mut names = HashSet::new();
        let mut templates = Vec::new();
        for (name, value) in value {
            let name = header_name(&name)?;
            if !names.insert(name.clone()) {
                return Err(ApiError::InvalidRequest);
            }
            templates.push((name, value));
        }
        Ok(Self(templates))
    }
}

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct BindingValue(HeaderValue);
impl TryFrom<String> for BindingValue {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, ApiError> {
        Ok(Self(header_value(&value)?))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AuthCapture {
    key: Option<SecretString>,
    #[serde(default)]
    extra_headers: HeaderTemplates,
    session: Option<BindingValue>,
    app_url: Option<BindingValue>,
}
#[derive(Default)]
pub(super) struct HeaderRules {
    kind: AuthKind,
    defaults: HeaderTemplates,
}
impl HeaderRules {
    pub fn new(kind: AuthKind, defaults: HeaderTemplates) -> Self {
        Self { kind, defaults }
    }
    pub fn build(
        &self,
        mut headers: HeaderMap,
        capture: AuthCapture,
    ) -> Result<HeaderMap, ApiError> {
        for (name, template) in &capture.extra_headers.0 {
            if headers.contains_key(name) {
                return Err(ApiError::InvalidRequest);
            }
            headers.insert(name.clone(), template.resolve(&capture)?);
        }
        for (name, template) in &self.defaults.0 {
            if !headers.contains_key(name) {
                headers.insert(name.clone(), template.resolve(&capture)?);
            }
        }
        if !headers.contains_key(CONTENT_TYPE) {
            headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        }
        if let Some(key) = capture.key.as_ref().filter(|key| !key.exposed().is_empty()) {
            let (name, value) = match self.kind {
                AuthKind::Bearer => {
                    let bearer = zeroize::Zeroizing::new(format!("Bearer {}", key.exposed()));
                    (
                        HeaderName::from_static("authorization"),
                        header_value(&bearer)?,
                    )
                }
                AuthKind::XApiKey => (
                    HeaderName::from_static("x-api-key"),
                    header_value(key.exposed())?,
                ),
            };
            if headers.contains_key(&name) {
                return Err(ApiError::InvalidRequest);
            }
            headers.insert(name, value);
        }
        check_size(&headers)?;
        Ok(headers)
    }
}
impl HeaderTemplate {
    fn resolve(&self, capture: &AuthCapture) -> Result<HeaderValue, ApiError> {
        match self {
            Self::Literal(value) => Ok(value.clone()),
            Self::Session => capture
                .session
                .as_ref()
                .map(|value| value.0.clone())
                .ok_or(ApiError::InvalidRequest),
            Self::AppUrl => capture
                .app_url
                .as_ref()
                .map(|value| value.0.clone())
                .ok_or(ApiError::InvalidRequest),
        }
    }
}
pub(super) fn header_name(value: &str) -> Result<HeaderName, ApiError> {
    let name = HeaderName::from_bytes(value.as_bytes()).map_err(|_| ApiError::InvalidRequest)?;
    if matches!(
        name.as_str(),
        "host" | "content-length" | "transfer-encoding" | "connection" | "proxy-authorization"
    ) {
        return Err(ApiError::InvalidRequest);
    }
    Ok(name)
}
pub(super) fn header_value(value: &str) -> Result<HeaderValue, ApiError> {
    if value.len() > 16 * 1024 {
        return Err(ApiError::Limit);
    }
    let mut value = HeaderValue::from_str(value).map_err(|_| ApiError::InvalidRequest)?;
    value.set_sensitive(true);
    Ok(value)
}
pub(super) fn check_size(headers: &HeaderMap) -> Result<(), ApiError> {
    let mut bytes = 0usize;
    if headers.len() > 64 {
        return Err(ApiError::Limit);
    }
    for (name, value) in headers {
        bytes = bytes
            .saturating_add(name.as_str().len())
            .saturating_add(value.len());
        if bytes > 64 * 1024 {
            return Err(ApiError::Limit);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn build(
        kind: AuthKind,
        defaults: Value,
        capture: Value,
    ) -> Result<HeaderMap, Box<dyn std::error::Error>> {
        Ok(HeaderRules::new(kind, serde_json::from_value(defaults)?)
            .build(HeaderMap::new(), serde_json::from_value(capture)?)?)
    }
    fn text<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
        headers.get(name).and_then(|value| value.to_str().ok())
    }
    #[test]
    fn bearer_x_api_key_empty_and_custom_auth_are_distinct() -> TestResult {
        let headers = build(AuthKind::Bearer, json!({}), json!({"key":"synthetic-key"}))?;
        assert_eq!(
            text(&headers, "authorization"),
            Some("Bearer synthetic-key")
        );
        assert!(
            headers
                .get("authorization")
                .is_some_and(HeaderValue::is_sensitive)
        );
        assert_eq!(text(&headers, "content-type"), Some("application/json"));
        let headers = build(
            AuthKind::XApiKey,
            json!({"anthropic-version":"2023-06-01"}),
            json!({"key":"synthetic-key"}),
        )?;
        assert_eq!(text(&headers, "x-api-key"), Some("synthetic-key"));
        assert_eq!(text(&headers, "anthropic-version"), Some("2023-06-01"));
        assert!(!headers.contains_key("authorization"));
        for key in [Value::Null, json!("")] {
            let headers = build(AuthKind::Bearer, json!({}), json!({"key":key}))?;
            assert!(!headers.contains_key("authorization"));
        }
        let headers = build(
            AuthKind::Bearer,
            json!({}),
            json!({"extra_headers":{"Authorization":"Custom scheme"}}),
        )?;
        assert_eq!(text(&headers, "authorization"), Some("Custom scheme"));
        assert!(
            build(
                AuthKind::Bearer,
                json!({}),
                json!({"key":"synthetic-key","extra_headers":{"Authorization":"Conflicting"}})
            )
            .is_err()
        );
        Ok(())
    }
    #[test]
    fn bound_headers_are_captured_and_overrides_are_case_insensitive() -> TestResult {
        let headers = build(
            AuthKind::Bearer,
            json!({"X-Title":"baseline","HTTP-Referer":{"binding":"app-url"}}),
            json!({"app_url":"https://local.invalid/kargu","session":"session-fixture","extra_headers":{"x-title":"custom","x-opencode-session":{"binding":"session"}}}),
        )?;
        assert_eq!(text(&headers, "x-title"), Some("custom"));
        assert_eq!(
            text(&headers, "http-referer"),
            Some("https://local.invalid/kargu")
        );
        assert_eq!(
            text(&headers, "x-opencode-session"),
            Some("session-fixture")
        );
        assert!(
            build(
                AuthKind::Bearer,
                json!({"x-session":{"binding":"session"}}),
                json!({})
            )
            .is_err()
        );
        let overridden = build(
            AuthKind::Bearer,
            json!({"x-session":{"binding":"session"}}),
            json!({"extra_headers":{"X-SESSION":"explicit"}}),
        )?;
        assert_eq!(text(&overridden, "x-session"), Some("explicit"));
        Ok(())
    }
    #[test]
    fn unsafe_and_ambiguous_templates_fail_before_io() -> TestResult {
        for value in [
            json!({"Host":"other.invalid"}),
            json!({"Content-Length":"12"}),
            json!({"x-header":"bad\r\nHost: injected"}),
            json!({"X-Title":"a","x-title":"b"}),
            json!({"x-session":{"binding":"unknown"}}),
            json!({"x-session":{"binding":"session","extra":true}}),
        ] {
            assert!(serde_json::from_value::<HeaderTemplates>(value).is_err());
        }
        assert!(build(AuthKind::Bearer, json!({}), json!({"key":"bad\r\nkey"})).is_err());
        assert!(
            build(
                AuthKind::Bearer,
                json!({"x-session":{"binding":"session"}}),
                json!({"session":"bad\r\nvalue"})
            )
            .is_err()
        );
        Ok(())
    }
    #[test]
    fn aggregate_count_and_bytes_include_generated_headers() -> TestResult {
        let mut many = serde_json::Map::new();
        for index in 0..64 {
            many.insert(format!("x-{index}"), json!("v"));
        }
        assert!(build(AuthKind::Bearer, json!({}), json!({"extra_headers":many})).is_err());
        let mut large = serde_json::Map::new();
        for index in 0..4 {
            large.insert(format!("x-{index}"), json!("x".repeat(16 * 1024)));
        }
        assert!(build(AuthKind::Bearer, json!({}), json!({"extra_headers":large})).is_err());
        Ok(())
    }
    #[test]
    fn opaque_continuation_cannot_cross_credentials_or_tenant_headers() -> TestResult {
        let catalog: Value = serde_json::from_str(include_str!("../../assets/providers.json"))?;
        let capture = |key: &str,
                       tenant: &str|
         -> Result<crate::api::HttpRequest, serde_json::Error> {
            serde_json::from_value(
                json!({"url":"http://localhost/messages","method":"post","headers":{},"stream":false,
                "body":"{\"model\":\"fixture\",\"messages\":[]}","wire":catalog["formats"]["anthropic"],
                "auth":{"key":key,"extra_headers":{"x-tenant":tenant}},
                "timeouts":{"connect_ms":1,"first_byte_ms":1,"idle_ms":null,"deadline_ms":null}}),
            )
        };
        let first = capture("first-key", "tenant-a")?;
        let result=first.wire.decode(json!({"type":"message","content":[{"type":"thinking","thinking":"thought","signature":"opaque-fixture-signature"}]}))?;
        let payload = json!({"model":"fixture","messages":[result["choices"][0]["message"]]});
        let same = capture("first-key", "tenant-a")?;
        assert!(
            same.wire
                .encode(payload.clone())?
                .to_string()
                .contains("opaque-fixture-signature")
        );
        for other in [
            capture("other-key", "tenant-a")?,
            capture("first-key", "tenant-b")?,
        ] {
            assert!(
                !other
                    .wire
                    .encode(payload.clone())?
                    .to_string()
                    .contains("opaque-fixture-signature")
            );
        }
        Ok(())
    }
}
