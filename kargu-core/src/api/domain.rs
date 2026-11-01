//! Parse-once HTTP authority, secret headers and independent network timers.

use super::ApiError;
use crate::providers::ApiEndpoint;
use reqwest::{Method, header::HeaderMap};
use serde::Deserialize;
use std::{collections::BTreeMap, fmt, sync::Arc, time::Duration};
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
        #[derive(Clone, Copy, Deserialize)]
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

#[derive(Clone, Copy, Deserialize)]
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
    pub(super) wire: Arc<super::wire::WireCodec>,
    pub(super) response_profile: ResponseProfile,
}

struct ConnectionInput {
    url: ApiEndpoint,
    target: RequestTarget,
    provider: Option<crate::providers::ApiProviderId>,
    headers: BTreeMap<String, SecretString>,
    wire: Option<super::wire::WireSpec>,
    auth: Option<super::auth::AuthCapture>,
}
struct CapturedConnection {
    authority: super::ApiAuthority,
    provider: Option<crate::providers::ApiProviderId>,
    url: ApiEndpoint,
    headers: HeaderMap,
    wire: Arc<super::wire::WireCodec>,
}
impl ConnectionInput {
    fn capture(self, model: Option<&ModelId>) -> Result<CapturedConnection, ApiError> {
        if self.headers.len() > 64 {
            return Err(ApiError::Limit);
        }
        let mut headers = HeaderMap::new();
        for (name, value) in self.headers {
            let name = super::auth::header_name(&name)?;
            if headers.contains_key(&name) {
                return Err(ApiError::InvalidRequest);
            }
            headers.insert(name, super::auth::header_value(value.exposed())?);
        }
        super::auth::check_size(&headers)?;
        let spec = self.wire.unwrap_or_default();
        let url = match self.target {
            RequestTarget::Exact => self.url,
            RequestTarget::Chat => spec.chat_endpoint(self.url)?,
        };
        let wire = spec.bind(&url, model, self.provider.as_ref())?;
        let headers = wire.headers(headers, self.auth)?;
        let wire = Arc::new(wire.capture_headers(&headers)?);
        let authority = super::ApiAuthority::capture(&url, self.provider.as_ref(), &headers)?;
        Ok(CapturedConnection {
            authority,
            provider: self.provider,
            url,
            headers,
            wire,
        })
    }
}

fn encode_body(
    mut value: serde_json::Value,
    wire: &super::wire::WireCodec,
    stream: bool,
    tuning: &super::policy::RequestTuning,
    cache_markers: bool,
) -> Result<Zeroizing<String>, ApiError> {
    if !value.is_object()
        || (stream
            && (!wire.streams()
                || value.get("stream").and_then(serde_json::Value::as_bool) != Some(true)))
    {
        return Err(ApiError::InvalidRequest);
    }
    value = wire.tune(value, tuning)?;
    if cache_markers {
        super::cache::prepare(&mut value)?;
    }
    let body = Zeroizing::new(wire.encode(value)?.to_string());
    if body.len() > crate::constants::limits::API_REQUEST_BYTES {
        return Err(ApiError::Limit);
    }
    Ok(body)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChatConnectionInput {
    model: ModelId,
    url: ApiEndpoint,
    headers: BTreeMap<String, SecretString>,
    stream: bool,
    timeouts: Timeouts,
    #[serde(default)]
    limits: super::stream::StreamLimits,
    wire: Option<super::wire::WireSpec>,
    provider: Option<crate::providers::ApiProviderId>,
    #[serde(default)]
    cache_markers: bool,
    #[serde(default)]
    tuning: super::policy::RequestTuning,
    auth: Option<super::auth::AuthCapture>,
}

/// Captured native chat connection. Model, tenant, credentials, wire policy and
/// endpoint remain fixed across all model turns and physical retries of a run.
/// It cannot be serialized or printed, and performs no credential lookup or IO.
#[derive(Deserialize)]
#[serde(try_from = "ChatConnectionInput")]
pub struct ChatConnection {
    model: ModelId,
    connection: CapturedConnection,
    stream: bool,
    timeouts: Timeouts,
    limits: super::stream::StreamLimits,
    tuning: super::policy::RequestTuning,
    cache_markers: bool,
}
impl TryFrom<ChatConnectionInput> for ChatConnection {
    type Error = ApiError;
    fn try_from(input: ChatConnectionInput) -> Result<Self, ApiError> {
        let connection = ConnectionInput {
            url: input.url,
            target: RequestTarget::Chat,
            provider: input.provider,
            headers: input.headers,
            wire: input.wire,
            auth: input.auth,
        }
        .capture(Some(&input.model))?;
        if input.stream && !connection.wire.streams() {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self {
            model: input.model,
            connection,
            stream: input.stream,
            timeouts: input.timeouts,
            limits: input.limits,
            tuning: input.tuning,
            cache_markers: input.cache_markers,
        })
    }
}
impl ChatConnection {
    /// Prepare only from the actual native model ticket, on a bounded worker.
    /// Reuses the existing wire/auth/tuning/cache implementation; history stays immutable.
    pub fn prepare_turn(
        &self,
        turn: &crate::application::agent::ModelTurn,
    ) -> Result<HttpRequest, ApiError> {
        let canonical = turn.canonical_payload(&self.model, self.stream)?;
        let value = serde_json::from_str(canonical.get()).map_err(|_| ApiError::InvalidRequest)?;
        let body = encode_body(
            value,
            &self.connection.wire,
            self.stream,
            &self.tuning,
            self.cache_markers,
        )?;
        turn.run().check_live().map_err(|error| match error {
            crate::error::CoreError::Deadline => ApiError::RunDeadline,
            _ => ApiError::Cancelled,
        })?;
        Ok(HttpRequest {
            authority: self.connection.authority.clone(),
            provider: self.connection.provider.clone(),
            url: self.connection.url.clone(),
            method: Method::POST,
            headers: self.connection.headers.clone(),
            body: Some(body),
            timeouts: self.timeouts,
            limits: self.limits,
            wire: self.connection.wire.clone(),
            response_profile: ResponseProfile::Raw,
        })
    }
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
                .is_some_and(|body| body.len() > crate::constants::limits::API_REQUEST_BYTES)
            || (matches!(dto.method, HttpMethod::Get) && (dto.body.is_some() || dto.stream))
        {
            return Err(ApiError::Limit);
        }
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
        let connection = ConnectionInput {
            url: dto.url,
            target: dto.target,
            provider: dto.provider,
            headers: dto.headers,
            wire: dto.wire,
            auth: dto.auth,
        }
        .capture(model.as_ref())?;
        let body = if let Some(value) = value {
            Some(encode_body(
                value,
                &connection.wire,
                dto.stream,
                &dto.tuning.unwrap_or_default(),
                dto.cache_markers,
            )?)
        } else {
            if matches!(dto.method, HttpMethod::Post) {
                return Err(ApiError::InvalidRequest);
            }
            None
        };
        Ok(Self {
            authority: connection.authority,
            provider: connection.provider,
            url: connection.url,
            method: match dto.method {
                HttpMethod::Get => Method::GET,
                HttpMethod::Post => Method::POST,
            },
            headers: connection.headers,
            body,
            timeouts: dto.timeouts,
            limits: dto.limits,
            wire: connection.wire,
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
