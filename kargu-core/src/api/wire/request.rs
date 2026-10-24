use super::{
    ApiError,
    domain::{OutputLimit, RequestRules, TextRule},
};
use serde_json::{Map, Value, json};

fn blocks(content: Option<&Value>, text: &TextRule) -> Result<Vec<Value>, ApiError> {
    match content {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::String(value)) if value.is_empty() => Ok(Vec::new()),
        Some(Value::String(value)) => Ok(vec![
            json!({"type":text.kind.as_str(),text.field.as_str():value}),
        ]),
        Some(Value::Array(value)) => Ok(value.clone()),
        _ => Err(ApiError::InvalidRequest),
    }
}
fn flush(pending: &mut Vec<Value>, messages: &mut Vec<Value>) {
    if !pending.is_empty() {
        messages.push(json!({"role":"user","content":std::mem::take(pending)}));
    }
}
fn tool_call(call: &Value, rules: &RequestRules) -> Result<Value, ApiError> {
    let id = call
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .ok_or(ApiError::InvalidRequest)?;
    let function = call
        .get("function")
        .and_then(Value::as_object)
        .ok_or(ApiError::InvalidRequest)?;
    let input = match function.get("arguments") {
        None | Some(Value::Null) => json!({}),
        Some(Value::String(value)) if value.is_empty() => json!({}),
        Some(Value::String(value)) => {
            serde_json::from_str(value).map_err(|_| ApiError::InvalidRequest)?
        }
        Some(value) => value.clone(),
    };
    if !input.is_object() {
        return Err(ApiError::InvalidRequest);
    }
    Ok(
        json!({"type":rules.tool.kind.as_str(),rules.tool.id.as_str():id,
        rules.tool.name.as_str():function.get("name").and_then(Value::as_str).unwrap_or("tool"),rules.tool.input.as_str():input}),
    )
}
pub(super) fn encode(payload: Value, rules: &RequestRules) -> Result<Value, ApiError> {
    let payload = payload.as_object().ok_or(ApiError::InvalidRequest)?;
    // This block protocol has one explicit output-cap field.  Never silently
    // discard a cap selected by contradictory custom metadata.
    if payload.contains_key("max_completion_tokens") {
        return Err(ApiError::InvalidRequest);
    }
    let input = payload
        .get("messages")
        .and_then(Value::as_array)
        .ok_or(ApiError::InvalidRequest)?;
    let mut system = Vec::new();
    let mut messages = Vec::new();
    let mut pending = Vec::new();
    for message in input {
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .ok_or(ApiError::InvalidRequest)?;
        match role {
            "system" => system.extend(blocks(message.get("content"), &rules.text)?),
            "tool" => {
                let id = message
                    .get("tool_call_id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.trim().is_empty())
                    .ok_or(ApiError::InvalidRequest)?;
                let content = message.get("content").cloned().unwrap_or(json!(""));
                pending.push(json!({
                    "type": rules.result.kind.as_str(),
                    rules.result.id.as_str(): id,
                    rules.result.content.as_str(): content
                }));
            }
            "assistant" => {
                flush(&mut pending, &mut messages);
                let mut content = message
                    .get("_kargu_opaque_content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                content.extend(blocks(message.get("content"), &rules.text)?);
                if let Some(calls) = message.get("tool_calls").filter(|calls| !calls.is_null()) {
                    for call in calls.as_array().ok_or(ApiError::InvalidRequest)? {
                        content.push(tool_call(call, rules)?);
                    }
                }
                if !content.is_empty() {
                    messages.push(json!({"role": "assistant", "content": content}));
                }
            }
            "user" | "developer" => {
                pending.extend(blocks(message.get("content"), &rules.text)?);
                flush(&mut pending, &mut messages);
            }
            _ => return Err(ApiError::InvalidRequest),
        }
    }
    flush(&mut pending, &mut messages);
    let mut body = Map::new();
    body.insert(
        "model".to_owned(),
        payload
            .get("model")
            .cloned()
            .ok_or(ApiError::InvalidRequest)?,
    );
    body.insert("messages".to_owned(), json!(messages));
    body.insert(
        "max_tokens".to_owned(),
        json!(
            payload
                .get("max_tokens")
                .map(|value| serde_json::from_value::<OutputLimit>(value.clone()))
                .transpose()
                .map_err(|_| ApiError::InvalidRequest)?
                .unwrap_or(rules.max_tokens)
        ),
    );
    for key in &rules.copy {
        if let Some(value) = payload.get(key.as_str()) {
            body.insert(key.as_str().to_owned(), value.clone());
        }
    }
    if let Some(key) = rules.system.as_ref()
        && !system.is_empty()
    {
        body.insert(key.as_str().to_owned(), json!(system));
    }
    if let Some(tools) = payload.get("tools").filter(|value| !value.is_null()) {
        let mut normalized = Vec::new();
        for tool in tools.as_array().ok_or(ApiError::InvalidRequest)? {
            let function = tool.get("function").unwrap_or(tool);
            let name = function
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .ok_or(ApiError::InvalidRequest)?;
            let mut definition = json!({"name":name,"description":function.get("description").and_then(Value::as_str).unwrap_or(""),
                rules.schema.as_str():function.get("parameters").cloned().unwrap_or(json!({}))});
            if let Some(marker) = tool.get("cache_control") {
                definition["cache_control"] = marker.clone();
            }
            normalized.push(definition);
        }
        if !normalized.is_empty() {
            body.insert("tools".to_owned(), json!(normalized));
        }
    }
    Ok(Value::Object(body))
}
