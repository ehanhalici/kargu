//! Stable terminal failure categories for editor projection, never replay rights.

use super::ApiError;
use serde::Serialize;

/// Closed semantic labels. Editors translate these labels, not error prose,
/// curl exit codes or status guesses. Retry/circuit decisions still use ApiError.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FailureCategory {
    /// Captured input cannot be admitted.
    InvalidRequest,
    /// A bounded local resource was exhausted.
    ResourceLimit,
    /// The operation's owner revoked it.
    Cancelled,
    /// Ambiguous connection/DNS/TLS failure, not proof of an unhealthy provider.
    ConnectionFailed,
    /// A physical transport deadline expired.
    Timeout,
    /// The logical owner budget refused or expired.
    BudgetExhausted,
    /// Local retry coordination could not authorize another physical attempt.
    RetryUnavailable,
    /// An HTTP redirect was not followed.
    RedirectRefused,
    /// The upstream rejected the request syntax.
    BadRequest,
    /// The upstream rejected authentication.
    AuthenticationFailed,
    /// The upstream denied permission.
    PermissionDenied,
    /// The upstream resource was not found.
    NotFound,
    /// The upstream rate limited the request.
    RateLimitExceeded,
    /// A classified upstream internal/unavailable response.
    ServerError,
    /// An upstream gateway failed.
    BadGateway,
    /// An upstream gateway timed out.
    GatewayTimeout,
    /// An explicit upstream overload status.
    Overloaded,
    /// Another HTTP failure; its exact status remains separate metadata.
    HttpError,
    /// A typed provider code identified context overflow.
    ContextOverflow,
    /// The response violated the captured protocol.
    ProtocolError,
    /// The provider did not publish a terminal stream marker.
    IncompleteStream,
}

impl ApiError {
    /// Editor-facing semantic kind. It cannot authorize a retry, probe or charge.
    pub fn category(&self) -> FailureCategory {
        match self {
            Self::InvalidRequest => FailureCategory::InvalidRequest,
            Self::Limit => FailureCategory::ResourceLimit,
            Self::Cancelled => FailureCategory::Cancelled,
            Self::Connection => FailureCategory::ConnectionFailed,
            Self::FirstByteTimeout | Self::IdleTimeout | Self::Deadline => FailureCategory::Timeout,
            Self::RunDeadline | Self::BudgetRefused(_) => FailureCategory::BudgetExhausted,
            Self::RetryUnavailable => FailureCategory::RetryUnavailable,
            Self::Redirect => FailureCategory::RedirectRefused,
            Self::ContextOverflow { .. } => FailureCategory::ContextOverflow,
            Self::Protocol => FailureCategory::ProtocolError,
            Self::Incomplete => FailureCategory::IncompleteStream,
            Self::Http { status, .. } => match status.as_u16() {
                400 => FailureCategory::BadRequest,
                401 => FailureCategory::AuthenticationFailed,
                403 => FailureCategory::PermissionDenied,
                404 => FailureCategory::NotFound,
                429 => FailureCategory::RateLimitExceeded,
                500 | 503 => FailureCategory::ServerError,
                502 => FailureCategory::BadGateway,
                504 => FailureCategory::GatewayTimeout,
                529 => FailureCategory::Overloaded,
                _ => FailureCategory::HttpError,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::budget::Refusal;
    use serde_json::json;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn every_non_http_failure_has_a_closed_native_category() {
        assert!(crate::constants::protocol::LIFECYCLE_CAPABILITIES.contains(&"api_failure"));
        for (error, category) in [
            (ApiError::InvalidRequest, FailureCategory::InvalidRequest),
            (ApiError::Limit, FailureCategory::ResourceLimit),
            (ApiError::Cancelled, FailureCategory::Cancelled),
            (ApiError::Connection, FailureCategory::ConnectionFailed),
            (ApiError::FirstByteTimeout, FailureCategory::Timeout),
            (ApiError::IdleTimeout, FailureCategory::Timeout),
            (ApiError::Deadline, FailureCategory::Timeout),
            (ApiError::RunDeadline, FailureCategory::BudgetExhausted),
            (
                ApiError::BudgetRefused(Refusal::Requests),
                FailureCategory::BudgetExhausted,
            ),
            (
                ApiError::RetryUnavailable,
                FailureCategory::RetryUnavailable,
            ),
            (ApiError::Redirect, FailureCategory::RedirectRefused),
            (
                ApiError::ContextOverflow {
                    status: reqwest::StatusCode::BAD_REQUEST,
                },
                FailureCategory::ContextOverflow,
            ),
            (ApiError::Protocol, FailureCategory::ProtocolError),
            (ApiError::Incomplete, FailureCategory::IncompleteStream),
        ] {
            assert_eq!(error.category(), category);
            assert_eq!(error.snapshot().get("category"), Some(&json!(category)));
        }
    }
    #[test]
    fn http_categories_preserve_exact_status_without_free_text_inference() -> TestResult {
        for (status, category) in [
            (400, FailureCategory::BadRequest),
            (401, FailureCategory::AuthenticationFailed),
            (403, FailureCategory::PermissionDenied),
            (404, FailureCategory::NotFound),
            (429, FailureCategory::RateLimitExceeded),
            (500, FailureCategory::ServerError),
            (502, FailureCategory::BadGateway),
            (503, FailureCategory::ServerError),
            (504, FailureCategory::GatewayTimeout),
            (529, FailureCategory::Overloaded),
            (418, FailureCategory::HttpError),
        ] {
            let error = ApiError::Http {
                status: reqwest::StatusCode::from_u16(status)?,
                retry_after: None,
            };
            let snapshot = error.snapshot();
            assert_eq!(error.category(), category);
            assert_eq!(snapshot.get("status"), Some(&json!(status)));
            assert_eq!(snapshot.get("category"), Some(&json!(category)));
            assert_eq!(snapshot.get("code"), Some(&json!("http")));
        }
        Ok(())
    }
    #[test]
    fn owner_deadline_stays_distinct_from_transport_timeout() {
        let owner = ApiError::RunDeadline.snapshot();
        assert_eq!(owner.get("category"), Some(&json!("budget-exhausted")));
        assert_eq!(owner.get("reason"), Some(&json!("deadline")));
        assert_eq!(owner.get("code"), Some(&json!("run_deadline")));
        assert_eq!(
            ApiError::Deadline.snapshot().get("category"),
            Some(&json!("timeout"))
        );
    }
}
