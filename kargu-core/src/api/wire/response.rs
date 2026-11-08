use super::{
    ApiError,
    domain::{Field, ResponseRules},
};
use crate::domain::{CacheWriteTokens, CachedTokens, InputTokens, OutputTokens, TokenCount};
use serde_json::{Map, Value, json};
use std::collections::HashSet;

fn fresh_call_id(used: &mut HashSet<String>) -> String {
    loop {
        let candidate = format!(
            "call_kargu_{}",
            &uuid::Uuid::new_v4().simple().to_string()[..12]
        );
        if used.insert(candidate.clone()) {
            return candidate;
        }
    }
}

fn last_json_object(trimmed: &str) -> Option<Value> {
    let mut de = serde_json::Deserializer::from_str(trimmed).into_iter::<Value>();
    let mut last = None;
    while let Some(Ok(val)) = de.next() {
        if val.is_object() {
            last = Some(val);
        }
    }
    last
}

fn recover_arguments(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "{}".to_owned(),
        Some(Value::Object(map)) => Value::Object(map.clone()).to_string(),
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed == "null" {
                "{}".to_owned()
            } else if trimmed.starts_with('{') {
                last_json_object(trimmed).map_or_else(|| trimmed.to_owned(), |v| v.to_string())
            } else {
                trimmed.to_owned()
            }
        }
        _ => "{}".to_owned(),
    }
}

fn normalize_tool_call(call: &mut Map<String, Value>, used_ids: &mut HashSet<String>) {
    let valid_id = call.get("id").and_then(Value::as_str).and_then(|s| {
        let trimmed = s.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    });
    let id = match valid_id {
        Some(id) if !used_ids.contains(&id) => {
            used_ids.insert(id.clone());
            id
        }
        _ => fresh_call_id(used_ids),
    };
    call.insert("id".to_owned(), json!(id));
    call.insert("type".to_owned(), json!("function"));
    if let Some(func) = call.get_mut("function").and_then(Value::as_object_mut) {
        let args = recover_arguments(func.get("arguments"));
        func.insert("arguments".to_owned(), json!(args));
    }
}

fn normalize_message(message: &mut Map<String, Value>, used_ids: &mut HashSet<String>) {
    if !message.contains_key("reasoning_content") {
        for key in ["reasoning", "reasoning_details", "thinking", "thought"] {
            if let Some(val) = message.get(key).and_then(Value::as_str)
                && !val.trim().is_empty()
            {
                message.insert("reasoning_content".to_owned(), json!(val));
                break;
            }
        }
    }
    for key in ["reasoning", "reasoning_details", "thinking", "thought"] {
        message.remove(key);
    }
    if !message.contains_key("tool_calls")
        && let Some(legacy) = message.remove("function_call")
        && legacy.is_object()
    {
        message.insert(
            "tool_calls".to_owned(),
            json!([{"type": "function", "function": legacy}]),
        );
    }
    if let Some(calls) = message.get_mut("tool_calls").and_then(Value::as_array_mut) {
        for call in calls {
            if let Some(call_obj) = call.as_object_mut() {
                normalize_tool_call(call_obj, used_ids);
            }
        }
    }
}

fn normalize_choices(mut response: Value) -> Result<Value, ApiError> {
    let Some(choices) = response.get_mut("choices").and_then(Value::as_array_mut) else {
        return Ok(response);
    };
    let mut used_ids = HashSet::new();
    for choice in choices {
        if let Some(message) = choice.get_mut("message").and_then(Value::as_object_mut) {
            normalize_message(message, &mut used_ids);
        }
    }
    Ok(response)
}

fn count<T>(
    value: Option<&Value>,
    parse: impl FnOnce(u64) -> Result<T, crate::error::CoreError>,
) -> Result<Option<T>, ApiError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => parse(value.as_u64().ok_or(ApiError::Protocol)?)
            .map(Some)
            .map_err(|_| ApiError::Limit),
    }
}
fn usage(value: &Value, rules: &ResponseRules) -> Result<Option<Value>, ApiError> {
    let Some(source) = value.get("usage").filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let source = source.as_object().ok_or(ApiError::Protocol)?;
    let mut mapped = Map::new();
    for (from, to) in &rules.usage {
        if let Some(value) = source.get(from.as_str()).filter(|value| !value.is_null()) {
            let value = count(Some(value), TokenCount::try_from)?.ok_or(ApiError::Protocol)?;
            mapped.insert(to.as_str().to_owned(), json!(value));
        }
    }
    if let Some(cache) = rules.cache().as_ref() {
        let read = count(source.get(cache.read().as_str()), CachedTokens::try_from)?;
        let write = count(
            source.get(cache.write().as_str()),
            CacheWriteTokens::try_from,
        )?;
        if cache.input_excludes_cache
            && let Some(input) = count(mapped.get("prompt_tokens"), InputTokens::try_from)?
        {
            let input = input
                .as_u64()
                .checked_add(read.map_or(0, CachedTokens::as_u64))
                .and_then(|input| input.checked_add(write.map_or(0, CacheWriteTokens::as_u64)))
                .ok_or(ApiError::Limit)?;
            mapped.insert(
                "prompt_tokens".to_owned(),
                json!(InputTokens::try_from(input).map_err(|_| ApiError::Limit)?),
            );
        }
        let mut detail = Map::new();
        if let Some(read) = read {
            detail.insert("cached_tokens".to_owned(), json!(read));
        }
        if let Some(write) = write {
            detail.insert("cache_write_tokens".to_owned(), json!(write));
        }
        if !detail.is_empty() {
            mapped.insert("prompt_tokens_details".to_owned(), Value::Object(detail));
        }
    }
    // The counters are separately typed at ingestion; no float token accounting.
    let _ = count(mapped.get("completion_tokens"), OutputTokens::try_from)?;
    Ok(Some(Value::Object(mapped)))
}
pub(super) fn decode(response: Value, rules: &ResponseRules) -> Result<Value, ApiError> {
    if response
        .get("error")
        .is_some_and(|value| !value.is_null() && value != false)
    {
        return Ok(response);
    }
    if response.get("choices").is_some() {
        return normalize_choices(response);
    }
    let detected = rules.detect().iter().any(|key| {
        response
            .get(key.as_str())
            .is_some_and(|value| !value.is_null())
    }) || rules
        .detect_type()
        .as_ref()
        .is_some_and(|kind| response.get("type").and_then(Value::as_str) == Some(kind.as_str()));
    if !detected {
        return Ok(response);
    }
    let content = response
        .get(rules.content().as_str())
        .and_then(Value::as_array)
        .ok_or(ApiError::Protocol)?;
    let mut text = String::new();
    let mut thought = String::new();
    let mut calls = Vec::new();
    let mut opaque = Vec::new();
    for block in content {
        let kind = block
            .get("type")
            .and_then(Value::as_str)
            .ok_or(ApiError::Protocol)?;
        if kind == rules.text().kind().as_str() {
            text.push_str(
                block
                    .get(rules.text().field().as_str())
                    .and_then(Value::as_str)
                    .ok_or(ApiError::Protocol)?,
            );
        } else if kind == rules.tool.kind.as_str() {
            calls.push(json!({"id":block.get(rules.tool.id.as_str()).cloned().unwrap_or(Value::Null),"type":"function","function":{
                "name":block.get(rules.tool.name.as_str()).and_then(Value::as_str).unwrap_or("tool"),
                "arguments":block.get(rules.tool.input.as_str()).cloned().unwrap_or(json!({})).to_string()}}));
        } else {
            if let Some(reasoning) = rules.reasoning().as_ref()
                && kind == reasoning.kind().as_str()
            {
                thought.push_str(
                    block
                        .get(reasoning.field().as_str())
                        .and_then(Value::as_str)
                        .ok_or(ApiError::Protocol)?,
                );
            }
            opaque.push(block.clone());
        }
    }
    let stop = rules
        .detect()
        .iter()
        .find_map(|key| response.get(key.as_str()).and_then(Value::as_str));
    let finish = stop
        .and_then(|stop| {
            rules
                .finish()
                .iter()
                .find(|(key, _)| key.as_str() == stop)
                .map(|(_, finish)| finish)
        })
        .unwrap_or(rules.finish_default());
    let mut message = Map::from_iter([
        ("role".to_owned(), json!("assistant")),
        ("content".to_owned(), json!(text)),
    ]);
    if !thought.is_empty() {
        message.insert("reasoning_content".to_owned(), json!(thought));
    }
    if !calls.is_empty() {
        message.insert("tool_calls".to_owned(), json!(calls));
    }
    if !opaque.is_empty() {
        message.insert("_kargu_opaque_content".to_owned(), json!(opaque));
    }
    let mut result = Map::from_iter([(
        "choices".to_owned(),
        json!([{"message":message,"finish_reason":Field::as_str(finish)}]),
    )]);
    if let Some(usage) = usage(&response, rules)? {
        result.insert("usage".to_owned(), usage);
    }
    normalize_choices(Value::Object(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn response_normalization_deduplicates_call_ids_and_converts_legacy() -> TestResult {
        let input = json!({
            "choices": [{
                "message": {
                    "role": "assistant",
                    "function_call": {
                        "name": "read_file",
                        "arguments": "{}"
                    }
                }
            }]
        });
        let normalized = normalize_choices(input)?;
        let message = &normalized["choices"][0]["message"];
        assert!(message.get("function_call").is_none());
        let calls = message["tool_calls"].as_array().ok_or("calls missing")?;
        assert_eq!(calls.len(), 1);
        let id = calls[0]["id"].as_str().ok_or("id missing")?;
        assert!(id.starts_with("call_kargu_"));
        assert_eq!(calls[0]["function"]["name"], "read_file");
        assert_eq!(calls[0]["function"]["arguments"], "{}");
        Ok(())
    }

    #[test]
    fn response_normalization_assigns_fresh_ids_to_duplicates_and_empty() -> TestResult {
        let input = json!({
            "choices": [{
                "message": {
                    "role": "assistant",
                    "tool_calls": [
                        {"id": "c1", "function": {"name": "f1", "arguments": ""}},
                        {"id": "c1", "function": {"name": "f2", "arguments": "{}"}},
                        {"id": "", "function": {"name": "f3", "arguments": null}}
                    ]
                }
            }]
        });
        let normalized = normalize_choices(input)?;
        let calls = normalized["choices"][0]["message"]["tool_calls"]
            .as_array()
            .ok_or("calls missing")?;
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[0]["id"], "c1");
        assert_eq!(calls[0]["function"]["arguments"], "{}");
        let id2 = calls[1]["id"].as_str().ok_or("id2 missing")?;
        assert!(id2.starts_with("call_kargu_"));
        assert_ne!(id2, "c1");
        let id3 = calls[2]["id"].as_str().ok_or("id3 missing")?;
        assert!(id3.starts_with("call_kargu_"));
        assert_ne!(id3, id2);
        assert_eq!(calls[2]["function"]["arguments"], "{}");
        Ok(())
    }

    #[test]
    fn response_normalization_recovers_concatenated_json_arguments() -> TestResult {
        let input = json!({
            "choices": [{
                "message": {
                    "role": "assistant",
                    "thinking": "internal thought",
                    "tool_calls": [
                        {"id": "c1", "function": {"name": "f1", "arguments": "{}{\"path\":\"file.txt\"}"}}
                    ]
                }
            }]
        });
        let normalized = normalize_choices(input)?;
        let message = &normalized["choices"][0]["message"];
        assert_eq!(message["reasoning_content"], "internal thought");
        assert!(message.get("thinking").is_none());
        let calls = message["tool_calls"].as_array().ok_or("calls missing")?;
        assert_eq!(calls[0]["function"]["arguments"], "{\"path\":\"file.txt\"}");
        Ok(())
    }
}
