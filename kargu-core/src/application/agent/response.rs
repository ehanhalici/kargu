//! Parse only a complete, normalized provider turn. SSE fragments cannot enter
//! the agent history or produce executable invocations.

use crate::{
    error::CoreError,
    history::{Message, Role},
};
use serde::Deserialize;
use serde_json::value::RawValue;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Finish {
    Stop,
    Tools,
    Length,
    Filtered,
    Other,
}

/// Validated completed provider turn, retaining opaque content in its message.
/// No Debug implementation can print source, reasoning, or provider signatures.
pub struct AssistantTurn {
    pub(super) message: Message,
    pub(super) finish: Finish,
    pub(super) answer: bool,
    pub(super) thought: bool,
}

#[derive(Deserialize)]
struct Envelope {
    choices: Vec<Choice>,
}
#[derive(Deserialize)]
struct Choice {
    message: Box<RawValue>,
    finish_reason: Option<String>,
}
#[derive(Deserialize)]
struct Content {
    content: Option<Box<RawValue>>,
    reasoning_content: Option<Box<RawValue>>,
    reasoning: Option<Box<RawValue>>,
    thinking: Option<Box<RawValue>>,
}
fn nonempty(value: &RawValue) -> bool {
    match serde_json::from_str::<serde_json::Value>(value.get()) {
        Ok(serde_json::Value::String(text)) => !text.trim().is_empty(),
        Ok(serde_json::Value::Array(blocks)) => !blocks.is_empty(),
        _ => false,
    }
}
impl TryFrom<Box<RawValue>> for AssistantTurn {
    type Error = CoreError;
    fn try_from(value: Box<RawValue>) -> Result<Self, CoreError> {
        if value.get().len() > crate::constants::limits::HISTORY_MESSAGE_BYTES {
            return Err(CoreError::Limit);
        }
        let envelope: Envelope =
            serde_json::from_str(value.get()).map_err(|_| CoreError::InvalidToolOutput)?;
        if envelope.choices.len() != 1 {
            return Err(CoreError::InvalidToolOutput);
        }
        let choice = envelope
            .choices
            .into_iter()
            .next()
            .ok_or(CoreError::InvalidToolOutput)?;
        let finish = match choice.finish_reason.as_deref() {
            Some("stop" | "end_turn") => Finish::Stop,
            Some("tool_calls" | "function_call" | "tool_use") => Finish::Tools,
            Some("length" | "max_tokens") => Finish::Length,
            Some("content_filter") => Finish::Filtered,
            Some(_) => Finish::Other,
            None => return Err(CoreError::InvalidToolOutput),
        };
        let content: Content =
            serde_json::from_str(choice.message.get()).map_err(|_| CoreError::InvalidToolOutput)?;
        let message = Message::try_from(choice.message)?;
        if message.role() != Role::Assistant
            || (!message.calls().is_empty() && !matches!(finish, Finish::Stop | Finish::Tools))
            || (message.calls().is_empty() && finish == Finish::Tools)
        {
            return Err(CoreError::InvalidToolOutput);
        }
        let answer = content.content.as_deref().is_some_and(nonempty);
        let thought = [
            content.reasoning_content,
            content.reasoning,
            content.thinking,
        ]
        .iter()
        .any(|value| value.as_deref().is_some_and(nonempty));
        Ok(Self {
            message,
            finish,
            answer,
            thought,
        })
    }
}
