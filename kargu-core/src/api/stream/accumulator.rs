use super::{ApiError, StreamLimits, parser::Event};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Eq, Ord, PartialEq, PartialOrd)]
struct ToolIndex(u64);
impl TryFrom<Option<&Value>> for ToolIndex {
    type Error = ApiError;
    fn try_from(value: Option<&Value>) -> Result<Self, ApiError> {
        match value {
            None => Ok(Self(0)),
            Some(Value::Number(number)) => number.as_u64().map(Self).ok_or(ApiError::Protocol),
            Some(Value::String(text))
                if !text.is_empty() && text.bytes().all(|c| c.is_ascii_digit()) =>
            {
                text.parse().map(Self).map_err(|_| ApiError::Protocol)
            }
            _ => Err(ApiError::Protocol),
        }
    }
}
#[derive(Default)]
struct ToolCall {
    id: String,
    name: String,
    arguments: String,
}
enum Completion {
    Receiving,
    Finished(Option<String>),
}
pub(super) struct Accumulator {
    limits: StreamLimits,
    completion: Completion,
    text: String,
    reasoning: String,
    calls: BTreeMap<ToolIndex, ToolCall>,
    usage: Option<Value>,
}
impl Accumulator {
    pub fn new(limits: StreamLimits) -> Self {
        Self {
            limits,
            completion: Completion::Receiving,
            text: String::new(),
            reasoning: String::new(),
            calls: BTreeMap::new(),
            usage: None,
        }
    }
    pub fn accept(&mut self, event: Event) -> Result<Option<Value>, ApiError> {
        let Event::Data(value) = event else {
            if matches!(self.completion, Completion::Receiving) {
                self.completion = Completion::Finished(None);
            }
            return Ok(None);
        };
        if let Some(usage) = value.get("usage").filter(|usage| !usage.is_null()) {
            self.usage = Some(usage.clone());
        }
        if matches!(self.completion, Completion::Finished(_)) {
            return Ok(None);
        }
        if value
            .get("error")
            .is_some_and(|error| !error.is_null() && error != false)
        {
            return Err(ApiError::Protocol);
        }
        if let Some(choice) = value
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
        {
            if let Some(delta) = choice.get("delta").filter(|value| !value.is_null()) {
                append_text(&mut self.text, delta.get("content"), self.limits.raw())?;
                for field in [
                    "reasoning_content",
                    "reasoning",
                    "reasoning_details",
                    "thinking",
                    "thought",
                ] {
                    let before = self.reasoning.len();
                    append_text(&mut self.reasoning, delta.get(field), self.limits.raw())?;
                    if self.reasoning.len() > before {
                        break;
                    }
                }
                if let Some(calls) = delta.get("tool_calls").filter(|value| !value.is_null()) {
                    for call in calls.as_array().ok_or(ApiError::Protocol)? {
                        self.fragment(call)?;
                    }
                } else if let Some(legacy) =
                    delta.get("function_call").filter(|value| !value.is_null())
                {
                    self.fragment(&json!({"index":0,"function":legacy}))?;
                }
            }
            if let Some(reason) = choice
                .get("finish_reason")
                .and_then(Value::as_str)
                .filter(|reason| !reason.is_empty())
            {
                self.completion = Completion::Finished(Some(reason.to_owned()));
            }
        }
        Ok(Some(value))
    }
    fn fragment(&mut self, fragment: &Value) -> Result<(), ApiError> {
        if !fragment.is_object() {
            return Err(ApiError::Protocol);
        }
        let index = ToolIndex::try_from(fragment.get("index"))?;
        if !self.calls.contains_key(&index) && self.calls.len() >= self.limits.calls() {
            return Err(ApiError::Limit);
        }
        let call = self.calls.entry(index).or_default();
        if let Some(id) = fragment
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            if !call.id.is_empty() && call.id != id {
                return Err(ApiError::Protocol);
            }
            call.id = id.to_owned();
        }
        if let Some(function) = fragment.get("function") {
            if let Some(name) = function
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
            {
                call.name = name.to_owned();
            }
            if let Some(arguments) = function.get("arguments").filter(|value| !value.is_null()) {
                let new = match arguments {
                    Value::String(text) => text.clone(),
                    other => other.to_string(),
                };
                let complete = |text: &str| serde_json::from_str::<Value>(text).is_ok();
                let replace =
                    call.arguments.is_empty() || (complete(&call.arguments) && complete(&new));
                let size = if replace {
                    new.len()
                } else {
                    call.arguments.len().saturating_add(new.len())
                };
                if size > self.limits.arguments() {
                    return Err(ApiError::Limit);
                }
                if replace {
                    call.arguments = new;
                } else {
                    call.arguments.push_str(&new);
                }
            }
        }
        Ok(())
    }
    pub fn finish(self) -> Result<Value, ApiError> {
        let Completion::Finished(reason) = self.completion else {
            return Err(ApiError::Incomplete);
        };
        let has_calls = !self.calls.is_empty();
        let mut message = json!({"role":"assistant","content":self.text});
        if !self.reasoning.is_empty() {
            message["reasoning_content"] = json!(self.reasoning);
        }
        if has_calls {
            message["tool_calls"] = self.calls.into_values().map(|call|
            json!({"id":call.id,"type":"function","function":{"name":call.name,"arguments":call.arguments}})).collect();
        }
        let mut response = json!({"choices":[{"index":0,"message":message,"finish_reason":reason.unwrap_or_else(|| if has_calls {"tool_calls"} else {"stop"}.to_owned())}]});
        if let Some(usage) = self.usage {
            response["usage"] = usage;
        }
        Ok(response)
    }
}
fn append_text(target: &mut String, value: Option<&Value>, limit: usize) -> Result<(), ApiError> {
    match value {
        Some(Value::String(text)) => {
            if target.len().saturating_add(text.len()) > limit {
                return Err(ApiError::Limit);
            }
            target.push_str(text);
        }
        Some(Value::Array(blocks)) => {
            for block in blocks {
                append_text(target, Some(block), limit)?;
            }
        }
        Some(Value::Object(object)) => {
            for field in ["text", "output_text", "summary", "content"] {
                let before = target.len();
                append_text(target, object.get(field), limit)?;
                if target.len() > before {
                    break;
                }
            }
        }
        _ => {}
    }
    Ok(())
}
