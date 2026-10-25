//! Cache boundaries on an owned canonical request, never on stored history.

use super::ApiError;
use serde_json::{Map, Value, json};

const RUNTIME_BOUNDARY: &str = "<runtime_environment>\n";

fn text_block(text: &str, marked: bool) -> Value {
    let mut block = Map::from_iter([
        ("type".to_owned(), json!("text")),
        ("text".to_owned(), json!(text)),
    ]);
    if marked {
        block.insert("cache_control".to_owned(), json!({"type":"ephemeral"}));
    }
    Value::Object(block)
}

fn split_system(text: &str) -> Result<Option<(Value, Value)>, ApiError> {
    let Some(offset) = text.find(RUNTIME_BOUNDARY).filter(|offset| *offset > 0) else {
        return Ok(None);
    };
    let stable = text.get(..offset).ok_or(ApiError::InvalidRequest)?;
    let runtime = text.get(offset..).ok_or(ApiError::InvalidRequest)?;
    Ok(Some((text_block(stable, true), text_block(runtime, false))))
}

fn mark(message: &mut Value) -> Result<bool, ApiError> {
    let Some(content) = message.get_mut("content") else {
        return Ok(false);
    };
    if let Some(text) = content.as_str() {
        if text.is_empty() {
            return Ok(false);
        }
        *content = json!([text_block(text, false)]);
    }
    let Some(blocks) = content.as_array_mut() else {
        return Ok(false);
    };
    for block in blocks.iter_mut().rev() {
        if block.get("type").and_then(Value::as_str) == Some("text")
            && block
                .get("text")
                .and_then(Value::as_str)
                .is_some_and(|text| !text.is_empty())
        {
            block
                .as_object_mut()
                .ok_or(ApiError::InvalidRequest)?
                .insert("cache_control".into(), json!({"type":"ephemeral"}));
            return Ok(true);
        }
    }
    Ok(false)
}

/// Apply explicitly captured cache policy before provider wire encoding.
pub fn prepare(payload: &mut Value) -> Result<(), ApiError> {
    if let Some(messages) = payload.get_mut("messages") {
        let messages = messages.as_array_mut().ok_or(ApiError::InvalidRequest)?;
        if let Some(first) = messages.first_mut()
            && first.get("role").and_then(Value::as_str) == Some("system")
        {
            let split = first
                .get("content")
                .and_then(Value::as_str)
                .map(split_system)
                .transpose()?
                .flatten();
            if let Some((stable, runtime)) = split {
                first
                    .as_object_mut()
                    .ok_or(ApiError::InvalidRequest)?
                    .insert("content".into(), json!([stable, runtime]));
            } else {
                mark(first)?;
            }
        }
        let completed = if messages
            .last()
            .and_then(|message| message.get("role"))
            .and_then(Value::as_str)
            == Some("tool")
        {
            messages.len()
        } else {
            messages.len().saturating_sub(1)
        };
        for message in messages.iter_mut().take(completed).rev() {
            if message.get("role").and_then(Value::as_str) != Some("system") && mark(message)? {
                break;
            }
        }
    }
    if let Some(tools) = payload.get_mut("tools") {
        let tools = tools.as_array_mut().ok_or(ApiError::InvalidRequest)?;
        if let Some(last) = tools.last_mut() {
            last.as_object_mut()
                .ok_or(ApiError::InvalidRequest)?
                .insert("cache_control".into(), json!({"type":"ephemeral"}));
        }
    }
    Ok(())
}
