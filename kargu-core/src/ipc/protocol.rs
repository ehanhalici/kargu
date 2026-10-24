//! Strict envelope classification and duplicate-key-safe JSON decoding.

use std::fmt;

use crate::constants::protocol;
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value, json};

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

    /// Preserve the original identity's wire representation.
    pub fn value(&self) -> Value {
        match self {
            Self::String(text) => json!(text),
            Self::Integer(number) => json!(number),
        }
    }
}

/// Classified envelopes, without ambiguous untagged deserialization.
#[derive(Debug)]
pub enum Message {
    /// Request (Some id) or notification (None).
    Call {
        /// Correlation identity, absent for a notification.
        id: Option<RpcId>,
        /// Method name.
        method: String,
        /// Structured method parameters.
        params: Value,
    },
    /// Response; a successful null result remains a success.
    Response {
        /// Correlation identity.
        id: RpcId,
        /// Result payload or structured error.
        outcome: Result<Value, Value>,
    },
}

/// A sanitized wire error. It never includes the input text.
#[derive(Clone, Debug, thiserror::Error)]
#[error("{message}")]
pub struct Fault {
    /// Standard or application error code.
    pub code: i64,
    /// Static safe description.
    pub message: &'static str,
    /// Stable machine-readable status.
    pub status: &'static str,
}

impl Fault {
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

/// Decode an envelope, rejecting duplicate keys at every nesting depth.
pub fn decode(line: &str) -> Result<Message, Fault> {
    let mut deserializer = serde_json::Deserializer::from_str(line);
    let strict = StrictValue::deserialize(&mut deserializer)
        .and_then(|v| {
            deserializer.end()?;
            Ok(v.0)
        })
        .map_err(|_| Fault {
            code: protocol::error_codes::PARSE,
            message: "Parse error",
            status: "parse_error",
        })?;
    let object = strict.as_object().ok_or_else(Fault::invalid)?;
    if object.get("jsonrpc").and_then(Value::as_str) != Some(protocol::JSONRPC) {
        return Err(Fault::invalid());
    }
    if let Some(method) = object.get("method") {
        let method = method
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(Fault::invalid)?;
        if object.contains_key("result") || object.contains_key("error") {
            return Err(Fault::invalid());
        }
        let id = object
            .get("id")
            .map(|value| RpcId::parse(value).ok_or_else(Fault::invalid))
            .transpose()?;
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        if !params.is_object() && !params.is_array() {
            return Err(Fault::invalid());
        }
        return Ok(Message::Call {
            id,
            method: method.into(),
            params,
        });
    }
    let id = object
        .get("id")
        .and_then(RpcId::parse)
        .ok_or_else(Fault::invalid)?;
    let outcome = match (object.get("result"), object.get("error")) {
        (Some(result), None) => Ok(result.clone()),
        (None, Some(error)) if valid_error(error) => Err(error.clone()),
        _ => return Err(Fault::invalid()),
    };
    Ok(Message::Response { id, outcome })
}

fn valid_error(value: &Value) -> bool {
    value.get("code").and_then(Value::as_i64).is_some()
        && value.get("message").and_then(Value::as_str).is_some()
}

// serde_json::Value normally overwrites duplicate object keys. This visitor
// rejects them before any method, identity or permission decision is made.
struct StrictValue(Value);

impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(StrictVisitor)
    }
}

struct StrictVisitor;

impl<'de> Visitor<'de> for StrictVisitor {
    type Value = StrictValue;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON value with unique keys")
    }
    fn visit_bool<E: de::Error>(self, value: bool) -> Result<Self::Value, E> {
        Ok(StrictValue(json!(value)))
    }
    fn visit_i64<E: de::Error>(self, value: i64) -> Result<Self::Value, E> {
        Ok(StrictValue(json!(value)))
    }
    fn visit_u64<E: de::Error>(self, value: u64) -> Result<Self::Value, E> {
        Ok(StrictValue(json!(value)))
    }
    fn visit_f64<E: de::Error>(self, value: f64) -> Result<Self::Value, E> {
        serde_json::Number::from_f64(value)
            .map(|n| StrictValue(Value::Number(n)))
            .ok_or_else(|| E::custom("non-finite JSON number"))
    }
    fn visit_str<E: de::Error>(self, value: &str) -> Result<Self::Value, E> {
        Ok(StrictValue(json!(value)))
    }
    fn visit_string<E: de::Error>(self, value: String) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::String(value)))
    }
    fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::Null))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = seq.next_element::<StrictValue>()? {
            values.push(value.0);
        }
        Ok(StrictValue(Value::Array(values)))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut values = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if values.contains_key(&key) {
                return Err(de::Error::custom("duplicate JSON key"));
            }
            values.insert(key, map.next_value::<StrictValue>()?.0);
        }
        Ok(StrictValue(Value::Object(values)))
    }
}
