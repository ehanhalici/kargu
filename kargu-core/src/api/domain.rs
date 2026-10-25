//! Parse-once HTTP authority, secret headers and independent network timers.

use super::ApiError;
use crate::providers::ApiEndpoint;
use reqwest::{Method, header::HeaderMap};
use serde::Deserialize;
use std::{collections::BTreeMap, fmt, time::Duration};
use zeroize::Zeroizing;

/// Open model namespace; never confused with a provider or external thread ID.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, serde::Serialize)]
#[serde(try_from = "String")]
pub struct ModelId(String);
impl TryFrom<String> for ModelId {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, ApiError> {
        if value.trim().is_empty() || value.len() > 512 || value.chars().any(char::is_control) {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(value))
    }
}
impl ModelId {
    /// Borrow its opaque, case-sensitive wire identity without provider folding.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A captured secret. Neither diagnostics nor serialization expose plaintext.
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub struct SecretString(Zeroizing<String>);
impl SecretString {
    pub(super) fn exposed(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for SecretString {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let value = Zeroizing::new(value);
        if value.len() > 16 * 1024 {
            return Err(ApiError::Limit);
        }
        Ok(Self(value))
    }
}
impl fmt::Debug for SecretString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}
impl fmt::Display for SecretString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

macro_rules! timeout_type {
    ($name:ident) => {
        #[derive(Deserialize)]
        #[serde(try_from = "u64")]
        struct $name(Duration);
        impl TryFrom<u64> for $name {
            type Error = ApiError;
            fn try_from(ms: u64) -> Result<Self, ApiError> {
                if !(1..=86_400_000).contains(&ms) {
                    return Err(ApiError::InvalidRequest);
                }
                Ok(Self(Duration::from_millis(ms)))
            }
        }
    };
}
timeout_type!(ConnectTimeout);
timeout_type!(FirstByteTimeout);
timeout_type!(IdleTimeout);
timeout_type!(RequestDeadline);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Timeouts {
    connect_ms: ConnectTimeout,
    first_byte_ms: FirstByteTimeout,
    idle_ms: Option<IdleTimeout>,
    deadline_ms: Option<RequestDeadline>,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum HttpMethod {
    Get,
    Post,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RequestTarget {
    #[default]
    Exact,
    Chat,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ResponseProfile {
    #[default]
    Raw,
    ModelCatalog,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RequestDto {
    url: ApiEndpoint,
    #[serde(default)]
    target: RequestTarget,
    method: HttpMethod,
    headers: BTreeMap<String, SecretString>,
    body: Option<String>,
    stream: bool,
    #[serde(default)]
    response_profile: ResponseProfile,
    timeouts: Timeouts,
    #[serde(default)]
    limits: super::stream::StreamLimits,
    wire: Option<super::wire::WireSpec>,
    provider: Option<crate::providers::ApiProviderId>,
    #[serde(default)]
    cache_markers: bool,
    tuning: Option<super::policy::RequestTuning>,
    auth: Option<super::auth::AuthCapture>,
}

/// Immutable per-attempt HTTP capture, independent of mutable editor selection.
#[derive(Deserialize)]
#[serde(try_from = "RequestDto")]
pub struct HttpRequest {
    pub(crate) authority: super::ApiAuthority,
    pub(crate) provider: Option<crate::providers::ApiProviderId>,
    pub(super) url: ApiEndpoint,
    pub(super) method: Method,
    pub(super) headers: HeaderMap,
    pub(super) body: Option<Zeroizing<String>>,
    timeouts: Timeouts,
    pub(super) limits: super::stream::StreamLimits,
    pub(super) wire: super::wire::WireCodec,
    pub(super) response_profile: ResponseProfile,
}

impl TryFrom<RequestDto> for HttpRequest {
    type Error = ApiError;
    fn try_from(dto: RequestDto) -> Result<Self, ApiError> {
        if matches!(dto.target, RequestTarget::Chat)
            && (!matches!(dto.method, HttpMethod::Post)
                || !matches!(dto.response_profile, ResponseProfile::Raw))
        {
            return Err(ApiError::InvalidRequest);
        }
        if matches!(dto.response_profile, ResponseProfile::ModelCatalog)
            && !matches!(dto.method, HttpMethod::Get)
        {
            return Err(ApiError::InvalidRequest);
        }
        if dto.headers.len() > 64
            || dto
                .body
                .as_ref()
                .is_some_and(|body| body.len() > 768 * 1024)
            || (matches!(dto.method, HttpMethod::Get) && (dto.body.is_some() || dto.stream))
        {
            return Err(ApiError::Limit);
        }
        let mut headers = HeaderMap::new();
        for (name, value) in dto.headers {
            let name = super::auth::header_name(&name)?;
            if headers.contains_key(&name) {
                return Err(ApiError::InvalidRequest);
            }
            headers.insert(name, super::auth::header_value(value.exposed())?);
        }
        super::auth::check_size(&headers)?;
        let value = match dto.body.as_ref() {
            Some(body) => Some(
                serde_json::from_str::<serde_json::Value>(body)
                    .map_err(|_| ApiError::InvalidRequest)?,
            ),
            None => None,
        };
        let model = value
            .as_ref()
            .and_then(|value| value.get("model"))
            .map(|value| serde_json::from_value::<ModelId>(value.clone()))
            .transpose()
            .map_err(|_| ApiError::InvalidRequest)?;
        let spec = dto.wire.unwrap_or_default();
        let url = match dto.target {
            RequestTarget::Exact => dto.url,
            RequestTarget::Chat => spec.chat_endpoint(dto.url)?,
        };
        let wire = spec.bind(&url, model.as_ref(), dto.provider.as_ref())?;
        let headers = wire.headers(headers, dto.auth)?;
        let wire = wire.capture_headers(&headers)?;
        let body = if let Some(mut value) = value {
            if !value.is_object() {
                return Err(ApiError::InvalidRequest);
            }
            if dto.stream
                && (!wire.streams()
                    || value.get("stream").and_then(serde_json::Value::as_bool) != Some(true))
            {
                return Err(ApiError::InvalidRequest);
            }
            value = wire.tune(value, &dto.tuning.unwrap_or_default())?;
            if dto.cache_markers {
                super::cache::prepare(&mut value)?;
            }
            let encoded = wire.encode(value)?.to_string();
            if encoded.len() > 768 * 1024 {
                return Err(ApiError::Limit);
            }
            Some(Zeroizing::new(encoded))
        } else {
            if matches!(dto.method, HttpMethod::Post) {
                return Err(ApiError::InvalidRequest);
            }
            None
        };
        let authority = super::ApiAuthority::capture(&url, dto.provider.as_ref(), &headers)?;
        Ok(Self {
            authority,
            provider: dto.provider,
            url,
            method: match dto.method {
                HttpMethod::Get => Method::GET,
                HttpMethod::Post => Method::POST,
            },
            headers,
            body,
            timeouts: dto.timeouts,
            limits: dto.limits,
            wire,
            response_profile: dto.response_profile,
        })
    }
}
impl HttpRequest {
    pub(crate) fn generative(&self) -> bool {
        self.method == Method::POST
    }
    pub(super) fn connect_timeout(&self) -> Duration {
        self.timeouts.connect_ms.0
    }
    pub(super) fn first_byte_timeout(&self) -> Duration {
        self.timeouts.first_byte_ms.0
    }
    pub(super) fn idle_timeout(&self) -> Option<Duration> {
        self.timeouts.idle_ms.as_ref().map(|value| value.0)
    }
    pub(super) fn deadline(&self) -> Option<Duration> {
        self.timeouts.deadline_ms.as_ref().map(|value| value.0)
    }
}
