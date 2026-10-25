//! Owned model HTTP boundary. No shell, redirects, logs or ambient auth lookup.

mod auth;
pub mod cache;
mod domain;
mod http;
pub mod policy;
pub mod resilience;
pub mod stream;
pub mod wire;
pub use domain::{HttpRequest, ModelId, SecretString};
pub use http::execute;

use serde_json::{Value, json};

/// Payload-free failures: upstream bodies, URLs and credentials are not errors.
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    /// Invalid captured request or unsafe HTTP header.
    #[error("Invalid API request")]
    InvalidRequest,
    /// Any independent parser, body or output limit was reached.
    #[error("API resource limit exceeded")]
    Limit,
    /// Captured owner explicitly revoked the attempt.
    #[error("API request cancelled")]
    Cancelled,
    /// Connection/DNS/TLS setup failed without exposing its URL or diagnostics.
    #[error("API connection failed")]
    Connection,
    /// No response headers arrived within the independent first-byte bound.
    #[error("API first-byte timeout")]
    FirstByteTimeout,
    /// No body bytes arrived within the independent idle bound.
    #[error("API stream stalled")]
    IdleTimeout,
    /// The absolute per-attempt deadline expired.
    #[error("API deadline exceeded")]
    Deadline,
    /// Owner budget expired, not evidence of an unhealthy upstream service.
    #[error("Run budget deadline exceeded")]
    RunDeadline,
    /// HTTP redirect was refused before any target request or credential replay.
    #[error("API redirect refused; configure the final endpoint")]
    Redirect,
    /// HTTP failure; raw upstream error bodies are deliberately discarded.
    #[error("API HTTP status {status}")]
    Http {
        /// Upstream status code, never inferred from free text.
        status: reqwest::StatusCode,
        /// Allowlisted bounded Retry-After value only.
        retry_after: Option<String>,
    },
    /// An allowlisted provider code identified input/context overflow.
    #[error("API context length exceeded")]
    ContextOverflow {
        /// Original HTTP status, not a text-derived retry category.
        status: reqwest::StatusCode,
    },
    /// Malformed JSON, event or conflicting tool-call identity.
    #[error("Invalid API response")]
    Protocol,
    /// EOF without a provider terminal marker is not successful completion.
    #[error("Incomplete API stream")]
    Incomplete,
}
impl ApiError {
    /// Safe typed wire failure for the editor delivery adapter.
    pub fn snapshot(&self) -> Value {
        let code = match self {
            Self::InvalidRequest => "invalid_request",
            Self::Limit => "resource_limit",
            Self::Cancelled => "cancelled",
            Self::Connection => "connection_failed",
            Self::FirstByteTimeout => "first_byte_timeout",
            Self::IdleTimeout => "idle_timeout",
            Self::Deadline => "deadline",
            Self::RunDeadline => "run_deadline",
            Self::Redirect => "redirect_refused",
            Self::Http { .. } => "http",
            Self::ContextOverflow { .. } => "context_overflow",
            Self::Protocol => "protocol_error",
            Self::Incomplete => "incomplete_stream",
        };
        let mut result = json!({"code":code,"message":self.to_string()});
        if let Self::Http {
            status,
            retry_after,
        } = self
        {
            result["status"] = json!(status.as_u16());
            result["retry_after"] = json!(retry_after);
        }
        if let Self::ContextOverflow { status } = self {
            result["status"] = json!(status.as_u16());
        }
        result
    }
}
