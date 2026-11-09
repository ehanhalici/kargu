//! JSON-RPC value vocabulary shared by every module that answers a request.
//!
//! These are plain values, like the failure taxonomy; the transport that
//! frames and sends them stays in `ipc`.

use crate::constants::protocol;
use serde_json::{Value, json};

/// A request or response identity; integer and string identities stay distinct.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum RpcId {
    /// String request identity.
    String(String),
    /// Signed JSON integer request identity.
    Integer(i64),
}

impl RpcId {
    /// Parse a supported non-null JSON-RPC identity.
    pub fn parse(value: &Value) -> Option<Self> {
        match value {
            Value::String(text) => Some(Self::String(text.clone())),
            Value::Number(number) => number.as_i64().map(Self::Integer),
            _ => None,
        }
    }

    /// Reserve the exact serialized RPC envelope before constructing paged results.
    pub(crate) fn result_budget(
        &self,
        frame: super::ByteLimit,
    ) -> Result<super::ByteLimit, super::error::CoreError> {
        let envelope = serde_json::to_vec(&success(self, json!({})))
            .map_err(|_| super::error::CoreError::Limit)?;
        let overhead = envelope
            .len()
            .checked_sub(2)
            .ok_or(super::error::CoreError::Limit)?;
        super::ByteLimit::try_from(
            frame
                .as_usize()
                .checked_sub(overhead)
                .ok_or(super::error::CoreError::Limit)?,
        )
    }
    /// Preserve the original identity's wire representation.
    pub fn value(&self) -> Value {
        match self {
            Self::String(text) => json!(text),
            Self::Integer(number) => json!(number),
        }
    }
}

/// A sanitized wire error. It never includes the input text.
#[derive(Clone, Debug, thiserror::Error)]
#[error("{message}")]
pub struct Fault {
    code: i64,
    message: &'static str,
    status: &'static str,
}

impl Fault {
    /// A wire error from its code, static safe description and stable status.
    pub const fn new(code: i64, message: &'static str, status: &'static str) -> Self {
        Self {
            code,
            message,
            status,
        }
    }

    /// Standard or application error code.
    pub const fn code(&self) -> i64 {
        self.code
    }

    /// Static safe description.
    pub const fn message(&self) -> &'static str {
        self.message
    }

    /// Stable machine-readable status.
    pub const fn status(&self) -> &'static str {
        self.status
    }

    /// Construct a method-parameter rejection.
    pub fn params() -> Self {
        Self {
            code: protocol::error_codes::INVALID_PARAMS,
            message: "Invalid params",
            status: "invalid_params",
        }
    }

    /// Construct a protocol envelope rejection.
    pub fn invalid() -> Self {
        Self {
            code: protocol::error_codes::INVALID_REQUEST,
            message: "Invalid Request",
            status: "invalid_request",
        }
    }

    /// Encode a JSON-RPC error without echoing untrusted input.
    pub fn response(&self, id: Option<&RpcId>) -> Value {
        json!({"jsonrpc":protocol::JSONRPC, "id":id.map(RpcId::value),
               "error":{"code":self.code,"message":self.message,
                        "data":{"status":self.status}}})
    }
}

/// Wrap a successful response, including an explicit null result.
pub fn success(id: &RpcId, result: Value) -> Value {
    json!({"jsonrpc":protocol::JSONRPC, "id":id.value(), "result":result})
}
