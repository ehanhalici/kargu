//! Cached display text, derived at message ingress rather than on the editor.

use super::{HistoryError, Role};
use serde::Deserialize;
use serde_json::value::RawValue;
use std::sync::Arc;

#[derive(Deserialize)]
struct Block {
    #[serde(rename = "type")]
    kind: String,
    text: Option<Box<RawValue>>,
}

pub(super) fn capture(
    role: Role,
    content: Option<&RawValue>,
) -> Result<Option<Arc<str>>, HistoryError> {
    if role != Role::Assistant {
        return Ok(None);
    }
    let Some(content) = content else {
        return Ok(None);
    };
    let source = content.get().trim();
    if source == "null" {
        return Ok(None);
    }
    let text: String = if source.starts_with('"') {
        serde_json::from_str(source).map_err(|_| HistoryError::InvalidMessage)?
    } else {
        let blocks: Vec<Block> =
            serde_json::from_str(source).map_err(|_| HistoryError::InvalidMessage)?;
        let mut text = String::new();
        for block in blocks {
            if matches!(block.kind.as_str(), "text" | "output_text") {
                let source = block.text.ok_or(HistoryError::InvalidMessage)?;
                let part: String =
                    serde_json::from_str(source.get()).map_err(|_| HistoryError::InvalidMessage)?;
                text.push_str(&part);
            }
        }
        text
    };
    Ok(Some(Arc::from(text)))
}
