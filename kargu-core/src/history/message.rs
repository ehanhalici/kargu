use super::{HistoryError, ProviderCallId};
use crate::{constants::limits, domain::ToolName};
use serde::{Deserialize, Serialize, Serializer};
use serde_json::value::RawValue;
use std::collections::{BTreeMap, HashSet};

/// Canonical protocol role; legacy `model` is normalized once at ingress.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// System instructions.
    System,
    /// Developer instructions.
    Developer,
    /// User text and untrusted attachments.
    User,
    /// Completed model response, possibly carrying tool calls.
    #[serde(alias = "model")]
    Assistant,
    /// Exactly one committed tool result.
    Tool,
}

#[derive(Deserialize)]
struct FunctionInput {
    name: ToolName,
    arguments: String,
}
#[derive(Deserialize)]
struct CallInput {
    id: Option<ProviderCallId>,
    #[serde(rename = "type")]
    kind: Option<String>,
    function: FunctionInput,
}
#[derive(Deserialize)]
struct MessageInput {
    role: Role,
    content: Option<Box<RawValue>>,
    #[serde(default)]
    tool_calls: Option<Vec<Box<RawValue>>>,
    function_call: Option<Box<RawValue>>,
    tool_call_id: Option<ProviderCallId>,
    name: Option<Box<RawValue>>,
}

/// One parsed canonical call and its unchanged, valid JSON argument object.
/// It grants no execution permission.
#[derive(Clone)]
pub struct ProviderCall {
    id: ProviderCallId,
    name: ToolName,
    arguments: Box<RawValue>,
}
impl ProviderCall {
    /// Exact provider identity shared by history and result serialization.
    pub fn id(&self) -> &ProviderCallId {
        &self.id
    }
    /// Parsed tool name; registry canonicalization follows at the execution gate.
    pub fn name(&self) -> &ToolName {
        &self.name
    }
    /// Borrow the validated JSON argument object without reparsing message metadata.
    pub fn arguments(&self) -> &RawValue {
        &self.arguments
    }
}

/// A bounded canonical message. Raw provider fields exist only at this wire boundary.
/// No Debug implementation exposes text, attachments, reasoning or signatures.
#[derive(Clone, Deserialize)]
#[serde(try_from = "Box<RawValue>")]
pub struct Message {
    wire: Box<RawValue>,
    display: Option<std::sync::Arc<str>>,
    role: Role,
    calls: Vec<ProviderCall>,
    result_id: Option<ProviderCallId>,
    result_name: Option<ToolName>,
}

fn invalid<T>(_: T) -> HistoryError {
    HistoryError::InvalidMessage
}
fn raw<T: Serialize>(value: &T) -> Result<Box<RawValue>, HistoryError> {
    serde_json::value::to_raw_value(value).map_err(invalid)
}
fn object(value: &RawValue) -> Result<BTreeMap<String, Box<RawValue>>, HistoryError> {
    serde_json::from_str(value.get()).map_err(invalid)
}
fn validate_content(content: Option<&RawValue>) -> Result<(), HistoryError> {
    #[derive(Deserialize)]
    struct Block {
        #[serde(rename = "type")]
        kind: String,
    }
    let Some(content) = content else {
        return Ok(());
    };
    let trimmed = content.get().trim_start();
    if trimmed.starts_with('"') {
        let _: String = serde_json::from_str(content.get()).map_err(invalid)?;
        Ok(())
    } else if trimmed.starts_with('[') {
        let blocks: Vec<Block> = serde_json::from_str(content.get()).map_err(invalid)?;
        if blocks.len() > limits::HISTORY_CALLS {
            return Err(HistoryError::Limit);
        }
        for block in blocks {
            if block.kind.is_empty() || block.kind.len() > limits::TOOL_NAME_BYTES {
                return Err(HistoryError::InvalidMessage);
            }
        }
        Ok(())
    } else if trimmed.starts_with("null") {
        let () = serde_json::from_str(content.get()).map_err(invalid)?;
        Ok(())
    } else {
        Err(HistoryError::InvalidMessage)
    }
}

impl TryFrom<Box<RawValue>> for Message {
    type Error = HistoryError;
    fn try_from(mut wire: Box<RawValue>) -> Result<Self, HistoryError> {
        if wire.get().len() > limits::HISTORY_MESSAGE_BYTES {
            return Err(HistoryError::Limit);
        }
        let input: MessageInput = serde_json::from_str(wire.get()).map_err(invalid)?;
        validate_content(input.content.as_deref())?;
        if (input.role == Role::Tool) != input.tool_call_id.is_some()
            || (input.role != Role::Assistant
                && (input.function_call.is_some()
                    || input
                        .tool_calls
                        .as_ref()
                        .is_some_and(|calls| !calls.is_empty())))
        {
            return Err(HistoryError::InvalidMessage);
        }
        let mut fields = object(&wire)?;
        let role_wire = fields
            .get("role")
            .ok_or(HistoryError::InvalidMessage)?
            .get();
        let mut changed = input.role == Role::Assistant && role_wire != "\"assistant\"";
        if changed {
            fields.insert("role".into(), raw(&Role::Assistant)?);
        }
        let mut raw_calls = input.tool_calls.unwrap_or_default();
        if let Some(legacy) = input.function_call {
            if !raw_calls.is_empty() {
                return Err(HistoryError::InvalidMessage);
            }
            let call = BTreeMap::from([("type", raw(&"function")?), ("function", legacy)]);
            raw_calls.push(raw(&call)?);
            fields.remove("function_call");
            changed = true;
        }
        if raw_calls.len() > limits::HISTORY_CALLS {
            return Err(HistoryError::Limit);
        }
        let mut calls = Vec::with_capacity(raw_calls.len());
        let mut used = HashSet::new();
        for call in &mut raw_calls {
            let parsed: CallInput = serde_json::from_str(call.get()).map_err(invalid)?;
            if parsed
                .kind
                .as_deref()
                .is_some_and(|kind| kind != "function")
            {
                return Err(HistoryError::InvalidMessage);
            }
            let id = match parsed.id {
                Some(id) => id,
                None => {
                    let id = ProviderCallId::fresh();
                    let mut fields = object(call)?;
                    fields.insert("id".into(), raw(&id)?);
                    *call = raw(&fields)?;
                    changed = true;
                    id
                }
            };
            if !used.insert(id.clone()) {
                return Err(HistoryError::DuplicateCall);
            }
            let arguments = RawValue::from_string(parsed.function.arguments).map_err(invalid)?;
            // Struct field validation belongs to the selected tool. This boundary
            // only admits complete JSON objects, never partial SSE argument fragments.
            let _ = object(&arguments)?;
            calls.push(ProviderCall {
                id,
                name: parsed.function.name,
                arguments,
            });
        }
        if changed {
            if !raw_calls.is_empty() {
                fields.insert("tool_calls".into(), raw(&raw_calls)?);
            }
            wire = raw(&fields)?;
        }
        if wire.get().len() > limits::HISTORY_MESSAGE_BYTES {
            return Err(HistoryError::Limit);
        }
        let result_name = if input.role == Role::Tool {
            input
                .name
                .map(|name| serde_json::from_str(name.get()).map_err(invalid))
                .transpose()?
        } else {
            None
        };
        Ok(Self {
            display: super::presentation::capture(input.role, input.content.as_deref())?,
            wire,
            role: input.role,
            calls,
            result_id: input.tool_call_id,
            result_name,
        })
    }
}
impl Message {
    /// Canonical role parsed at ingress.
    pub fn role(&self) -> Role {
        self.role
    }
    /// Complete committed calls, distinct from stream fragments.
    pub fn calls(&self) -> &[ProviderCall] {
        &self.calls
    }
    /// Exact serialized message, preserving opaque multimodal/provider blocks.
    pub fn wire(&self) -> &RawValue {
        &self.wire
    }
    pub(super) fn bytes(&self) -> usize {
        self.wire
            .get()
            .len()
            .saturating_add(self.display.as_deref().map_or(0, str::len))
    }
    pub(super) fn display_text(&self) -> Option<&str> {
        self.display.as_deref()
    }
    pub(super) fn result_id(&self) -> Option<&ProviderCallId> {
        self.result_id.as_ref()
    }
    pub(super) fn result_name(&self) -> Option<&ToolName> {
        self.result_name.as_ref()
    }
    pub(crate) fn result(
        call: &ProviderCallId,
        name: &ToolName,
        text: &str,
    ) -> Result<Self, HistoryError> {
        let fields = BTreeMap::from([
            ("role", raw(&Role::Tool)?),
            ("tool_call_id", raw(call)?),
            ("name", raw(name)?),
            ("content", raw(&text)?),
        ]);
        Self::try_from(raw(&fields)?)
    }
}
impl Serialize for Message {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.wire.serialize(serializer)
    }
}
