//! Frame-bounded canonical conversation snapshots; this port cannot execute tools.

use super::{History, HistoryError, HistoryRevision};
use crate::{
    constants::{
        limits,
        protocol::{error_codes, methods},
    },
    domain::{ApiPageBytes, ByteLimit, MessageId},
    error::CoreError,
    ipc::protocol::Fault,
};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "usize")]
struct MessageCursor(usize);
impl TryFrom<usize> for MessageCursor {
    type Error = HistoryError;
    fn try_from(value: usize) -> Result<Self, HistoryError> {
        if value > limits::HISTORY_MESSAGES {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "usize")]
struct MessageOffset(usize);
impl TryFrom<usize> for MessageOffset {
    type Error = HistoryError;
    fn try_from(value: usize) -> Result<Self, HistoryError> {
        if value > limits::HISTORY_MESSAGE_BYTES {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MessagesInput {
    revision: Option<HistoryRevision>,
    offset: MessageCursor,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadInput {
    revision: HistoryRevision,
    message_id: MessageId,
    offset: MessageOffset,
    #[serde(default)]
    projection: Projection,
}
#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Projection {
    #[default]
    Wire,
    Display,
}
struct EncodedBytes(usize);

impl History {
    pub(crate) fn read_rpc(
        &self,
        method: &str,
        arguments: Value,
        frame: ByteLimit,
    ) -> Result<Value, Fault> {
        let result = match method {
            methods::HISTORY_MESSAGES => serde_json::from_value::<MessagesInput>(arguments)
                .map_err(|_| HistoryError::InvalidMessage)
                .and_then(|input| self.page_messages(input, frame)),
            methods::HISTORY_READ => serde_json::from_value::<ReadInput>(arguments)
                .map_err(|_| HistoryError::InvalidMessage)
                .and_then(|input| self.page_message(input, frame)),
            _ => Err(HistoryError::InvalidMessage),
        };
        result.map_err(|error| fault(error.into()))
    }
    fn page_messages(&self, input: MessagesInput, frame: ByteLimit) -> Result<Value, HistoryError> {
        if input
            .revision
            .is_some_and(|revision| revision != self.revision())
            || (input.offset.0 != 0 && input.revision.is_none())
        {
            return Err(HistoryError::StaleRevision);
        }
        if input.offset.0 > self.messages().len() {
            return Err(HistoryError::InvalidMessage);
        }
        let reserve = serde_json::to_vec(&json!({
            "revision":self.revision(),"offset":limits::HISTORY_MESSAGES,
            "next_offset":limits::HISTORY_MESSAGES,"complete":false,"messages":[]
        }))
        .map_err(|_| HistoryError::Limit)?
        .len();
        if reserve > frame.as_usize() {
            return Err(HistoryError::Limit);
        }
        let mut encoded = EncodedBytes(reserve);
        let mut rows = Vec::new();
        for message in self.messages().iter().skip(input.offset.0) {
            let row = json!({"message_id":message.id(),"role":message.message().role(),
                            "bytes":message.message().wire().get().len()});
            let row_bytes = serde_json::to_vec(&row)
                .map_err(|_| HistoryError::Limit)?
                .len();
            let next = encoded
                .0
                .checked_add(row_bytes)
                .and_then(|n| n.checked_add(1))
                .ok_or(HistoryError::Overflow)?;
            if next > frame.as_usize() {
                break;
            }
            rows.push(row);
            encoded = EncodedBytes(next);
        }
        let next = input
            .offset
            .0
            .checked_add(rows.len())
            .ok_or(HistoryError::Overflow)?;
        if next == input.offset.0 && next < self.messages().len() {
            return Err(HistoryError::Limit);
        }
        Ok(
            json!({"revision":self.revision(),"offset":input.offset.0,"next_offset":next,
                  "complete":next==self.messages().len(),"messages":rows}),
        )
    }
    fn page_message(&self, input: ReadInput, frame: ByteLimit) -> Result<Value, HistoryError> {
        if input.revision != self.revision() {
            return Err(HistoryError::StaleRevision);
        }
        let message = self
            .message(&input.message_id)
            .ok_or(HistoryError::InvalidMessage)?
            .message();
        let text = match input.projection {
            Projection::Wire => message.wire().get(),
            Projection::Display => message.display_text().ok_or(HistoryError::InvalidMessage)?,
        };
        let start = input.offset.0;
        if start > text.len() || !text.is_char_boundary(start) {
            return Err(HistoryError::InvalidMessage);
        }
        let bytes = ApiPageBytes::try_from(frame).map_err(|_| HistoryError::Limit)?;
        let end = text.floor_char_boundary(start.saturating_add(bytes.as_usize()).min(text.len()));
        let part = text.get(start..end).ok_or(HistoryError::InvalidMessage)?;
        let mut result = json!({"revision":self.revision(),"message_id":input.message_id,
                  "offset":start,"next_offset":end,"text":part,"complete":end==text.len()});
        if matches!(input.projection, Projection::Display) {
            result
                .as_object_mut()
                .ok_or(HistoryError::InvalidMessage)?
                .insert("projection".into(), json!("display"));
        }
        Ok(result)
    }
}

pub(crate) fn fault(error: CoreError) -> Fault {
    let (code, status, message) = match error {
        CoreError::Cancelled => (
            error_codes::CANCELLED,
            "cancelled",
            "Conversation import cancelled",
        ),
        CoreError::Deadline => (
            error_codes::TIMEOUT,
            "timeout",
            "Conversation import expired",
        ),
        CoreError::History(HistoryError::DuplicateCall) => (
            error_codes::INVALID_PARAMS,
            "duplicate_tool_call",
            "Tool call identity was already committed",
        ),
        CoreError::History(HistoryError::OrphanResult) => (
            error_codes::INVALID_PARAMS,
            "orphan_tool_result",
            "Tool result has no committed call",
        ),
        CoreError::History(HistoryError::DuplicateResult) => (
            error_codes::INVALID_PARAMS,
            "duplicate_tool_result",
            "Tool call already has a terminal result",
        ),
        CoreError::History(HistoryError::Limit) | CoreError::Limit => (
            error_codes::RESOURCE_LIMIT,
            "resource_limit",
            "Conversation capacity exceeded",
        ),
        CoreError::History(HistoryError::StaleRevision) | CoreError::StaleOwner => (
            error_codes::STALE_OWNER,
            "stale_history",
            "Conversation owner or revision changed",
        ),
        CoreError::Busy | CoreError::History(HistoryError::PendingCalls) => (
            error_codes::RESOURCE_LIMIT,
            "busy",
            "Conversation has active or unsettled work",
        ),
        _ => (
            error_codes::INVALID_PARAMS,
            "invalid_history",
            "Invalid conversation protocol",
        ),
    };
    Fault {
        code,
        status,
        message,
    }
}
