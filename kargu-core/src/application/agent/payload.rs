//! Canonical payload assembly for provider requests.
//! Disabled or empty tools omit both `tools` and `tool_choice`.
//! Extra fields cannot forge tools or override model/messages.

use crate::{
    api::{ApiError, ModelId},
    constants::limits,
    history::Message,
};
use serde_json::{Map, Value, json, value::RawValue};

/// Stream delivery mode for a canonical payload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PayloadStream(bool);

#[allow(dead_code)]
impl PayloadStream {
    /// Non-streaming single-response payload.
    pub const PLAIN: Self = Self(false);
    /// Server-sent events streaming payload.
    pub const STREAMING: Self = Self(true);

    /// Whether streaming mode is enabled.
    pub fn is_streaming(&self) -> bool {
        self.0
    }
}

impl From<bool> for PayloadStream {
    fn from(value: bool) -> Self {
        Self(value)
    }
}

/// Inputs for building a canonical provider request payload.
pub struct CanonicalPayloadSpec<'a> {
    model: &'a ModelId,
    tools: Option<&'a [Value]>,
    stream: PayloadStream,
    extra: Option<&'a Map<String, Value>>,
}

impl<'a> CanonicalPayloadSpec<'a> {
    /// Create payload specification with model, tools, and stream flag.
    pub(crate) fn new(
        model: &'a ModelId,
        tools: Option<&'a [Value]>,
        stream: PayloadStream,
    ) -> Self {
        Self {
            model,
            tools,
            stream,
            extra: None,
        }
    }

    /// Attach optional extra fields to merge.
    #[allow(dead_code)]
    pub(crate) fn with_extra(mut self, extra: Option<&'a Map<String, Value>>) -> Self {
        self.extra = extra;
        self
    }
}

fn merge_extra(payload: &mut Map<String, Value>, extra: &Map<String, Value>, enabled: bool) {
    for (key, val) in extra {
        if !enabled && (key == "tools" || key == "tool_choice") {
            continue;
        }
        if key == "model" || key == "messages" {
            continue;
        }
        payload.insert(key.clone(), val.clone());
    }
}

/// Assemble a canonical provider payload from model, messages, tools, and options.
/// Bounded by `limits::API_REQUEST_BYTES`.
pub(crate) fn build_canonical_payload<'a>(
    spec: CanonicalPayloadSpec<'a>,
    messages: impl IntoIterator<Item = &'a Message>,
) -> Result<Box<RawValue>, ApiError> {
    let enabled = spec.tools.is_some_and(|list| !list.is_empty());
    let mut payload = Map::new();
    payload.insert("model".to_owned(), json!(spec.model));
    let msgs: Vec<&'a Message> = messages.into_iter().collect();
    payload.insert("messages".to_owned(), json!(msgs));
    if enabled && let Some(tools) = spec.tools {
        payload.insert("tools".to_owned(), json!(tools));
        payload.insert("tool_choice".to_owned(), json!("auto"));
    }
    if spec.stream.is_streaming() {
        payload.insert("stream".to_owned(), json!(true));
    }
    if let Some(extra) = spec.extra {
        merge_extra(&mut payload, extra, enabled);
    }
    let raw = serde_json::value::to_raw_value(&payload).map_err(|_| ApiError::InvalidRequest)?;
    if raw.get().len() > limits::API_REQUEST_BYTES {
        return Err(ApiError::Limit);
    }
    Ok(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_message(role: &str, text: &str) -> Result<Message, Box<dyn std::error::Error>> {
        let raw = serde_json::value::to_raw_value(&json!({"role": role, "content": text}))?;
        Ok(Message::try_from(raw)?)
    }

    #[test]
    fn canonical_payload_tools_off_omits_tools_and_tool_choice()
    -> Result<(), Box<dyn std::error::Error>> {
        let model = ModelId::try_from("test-model".to_owned())?;
        let msg = test_message("user", "hello")?;
        let empty_tools: [Value; 0] = [];
        let spec = CanonicalPayloadSpec::new(&model, Some(&empty_tools), PayloadStream::PLAIN);
        let raw = build_canonical_payload(spec, [&msg])?;
        let parsed: Value = serde_json::from_str(raw.get())?;
        assert_eq!(parsed["model"], "test-model");
        assert!(parsed.get("tools").is_none());
        assert!(parsed.get("tool_choice").is_none());
        Ok(())
    }

    #[test]
    fn canonical_payload_extra_cannot_forge_tools_when_off()
    -> Result<(), Box<dyn std::error::Error>> {
        let model = ModelId::try_from("test-model".to_owned())?;
        let msg = test_message("user", "hello")?;
        let mut extra = Map::new();
        extra.insert("tools".to_owned(), json!([{"name": "forged"}]));
        extra.insert("tool_choice".to_owned(), json!("auto"));
        extra.insert("custom_field".to_owned(), json!("allowed"));
        let spec = CanonicalPayloadSpec::new(&model, None, PayloadStream::STREAMING)
            .with_extra(Some(&extra));
        let raw = build_canonical_payload(spec, [&msg])?;
        let parsed: Value = serde_json::from_str(raw.get())?;
        assert!(parsed.get("tools").is_none());
        assert!(parsed.get("tool_choice").is_none());
        assert_eq!(parsed["stream"], true);
        assert_eq!(parsed["custom_field"], "allowed");
        Ok(())
    }

    #[test]
    fn canonical_payload_with_tools_includes_tools_and_choice()
    -> Result<(), Box<dyn std::error::Error>> {
        let model = ModelId::try_from("test-model".to_owned())?;
        let msg = test_message("user", "hello")?;
        let tools = [json!({"type": "function", "function": {"name": "read_file"}})];
        let spec = CanonicalPayloadSpec::new(&model, Some(&tools), PayloadStream::PLAIN);
        let raw = build_canonical_payload(spec, [&msg])?;
        let parsed: Value = serde_json::from_str(raw.get())?;
        assert_eq!(parsed["tools"][0]["function"]["name"], "read_file");
        assert_eq!(parsed["tool_choice"], "auto");
        Ok(())
    }
}
