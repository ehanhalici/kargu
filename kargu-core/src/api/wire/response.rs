use super::{
    ApiError,
    domain::{Field, ResponseRules},
};
use crate::domain::{CachedTokens, InputTokens, OutputTokens, TokenCount};
use serde_json::{Map, Value, json};

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
    if let Some(cache) = rules.cache.as_ref() {
        let read = count(source.get(cache.read.as_str()), CachedTokens::try_from)?;
        let write = count(source.get(cache.write.as_str()), InputTokens::try_from)?;
        if cache.input_excludes_cache
            && let Some(input) = count(mapped.get("prompt_tokens"), InputTokens::try_from)?
        {
            let input = input
                .as_u64()
                .checked_add(read.map_or(0, CachedTokens::as_u64))
                .and_then(|input| input.checked_add(write.map_or(0, InputTokens::as_u64)))
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
    if response.get("choices").is_some()
        || response
            .get("error")
            .is_some_and(|value| !value.is_null() && value != false)
    {
        return Ok(response);
    }
    let detected = rules.detect.iter().any(|key| {
        response
            .get(key.as_str())
            .is_some_and(|value| !value.is_null())
    }) || rules
        .detect_type
        .as_ref()
        .is_some_and(|kind| response.get("type").and_then(Value::as_str) == Some(kind.as_str()));
    if !detected {
        return Ok(response);
    }
    let content = response
        .get(rules.content.as_str())
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
        if kind == rules.text.kind.as_str() {
            text.push_str(
                block
                    .get(rules.text.field.as_str())
                    .and_then(Value::as_str)
                    .ok_or(ApiError::Protocol)?,
            );
        } else if kind == rules.tool.kind.as_str() {
            calls.push(json!({"id":block.get(rules.tool.id.as_str()).cloned().unwrap_or(Value::Null),"type":"function","function":{
                "name":block.get(rules.tool.name.as_str()).and_then(Value::as_str).unwrap_or("tool"),
                "arguments":block.get(rules.tool.input.as_str()).cloned().unwrap_or(json!({})).to_string()}}));
        } else {
            if let Some(reasoning) = rules.reasoning.as_ref()
                && kind == reasoning.kind.as_str()
            {
                thought.push_str(
                    block
                        .get(reasoning.field.as_str())
                        .and_then(Value::as_str)
                        .ok_or(ApiError::Protocol)?,
                );
            }
            opaque.push(block.clone());
        }
    }
    let stop = rules
        .detect
        .iter()
        .find_map(|key| response.get(key.as_str()).and_then(Value::as_str));
    let finish = stop
        .and_then(|stop| {
            rules
                .finish
                .iter()
                .find(|(key, _)| key.as_str() == stop)
                .map(|(_, finish)| finish)
        })
        .unwrap_or(&rules.finish_default);
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
    Ok(Value::Object(result))
}
