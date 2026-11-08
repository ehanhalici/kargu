//! Protocol repair for incomplete turns, orphan prevention, and deterministic outcome_unknown injection.
//!
//! Enforces:
//! - Unfinished model/tool/edit calls receive exactly one `outcome_unknown` result message.
//! - Results are injected into the exact assistant/tool block in deterministic call order.
//! - Strict error rejection on duplicate tool call IDs or orphan tool results.
//! - Preservation of StartAction-only records.
//! - Complete idempotence: second load/repair performs zero duplicate insertions.

use crate::{
    error::CoreError,
    persistence::domain::{
        MessageContent, MessageRole, PersistedToolCallId, PersistedToolName, PersistenceError,
        SessionMessage, SessionRecord, SessionRepairCount,
    },
};
use std::collections::BTreeSet;

/// Scan and validate session messages, detecting duplicates, orphans, and repairing missing tool results.
pub fn repair_protocol(record: &mut SessionRecord) -> Result<SessionRepairCount, CoreError> {
    validate_protocol_integrity(record.messages())?;
    let (repaired_messages, repair_count) = build_repaired_messages(record.messages())?;
    if repair_count > 0 {
        record.set_messages(repaired_messages)?;
    }
    Ok(SessionRepairCount::from_usize(repair_count))
}

fn validate_protocol_integrity(messages: &[SessionMessage]) -> Result<(), CoreError> {
    let mut declared_calls = BTreeSet::new();
    let mut resolved_calls = BTreeSet::new();
    for msg in messages {
        match msg.role() {
            MessageRole::Assistant => {
                validate_assistant_calls(msg, &mut declared_calls)?;
            }
            MessageRole::Tool => {
                validate_tool_result(msg, &declared_calls, &mut resolved_calls)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn validate_assistant_calls(
    msg: &SessionMessage,
    declared: &mut BTreeSet<PersistedToolCallId>,
) -> Result<(), CoreError> {
    if let Some(calls) = msg.tool_calls() {
        for call in calls {
            if !declared.insert(call.id().clone()) {
                return Err(CoreError::from(PersistenceError::Validation(
                    "duplicate tool call id",
                )));
            }
        }
    }
    Ok(())
}

fn validate_tool_result(
    msg: &SessionMessage,
    declared: &BTreeSet<PersistedToolCallId>,
    resolved: &mut BTreeSet<PersistedToolCallId>,
) -> Result<(), CoreError> {
    let id = msg
        .tool_call_id()
        .ok_or_else(|| CoreError::from(PersistenceError::Validation("missing tool call id")))?;
    if !declared.contains(id) {
        return Err(CoreError::from(PersistenceError::Validation(
            "orphan tool result",
        )));
    }
    if !resolved.insert(id.clone()) {
        return Err(CoreError::from(PersistenceError::Validation(
            "duplicate tool result",
        )));
    }
    Ok(())
}

fn build_repaired_messages(
    messages: &[SessionMessage],
) -> Result<(Vec<SessionMessage>, usize), CoreError> {
    let mut repaired = Vec::with_capacity(messages.len());
    let mut pending_repairs: Vec<(PersistedToolCallId, Option<PersistedToolName>)> = Vec::new();
    let mut repair_count: usize = 0;
    for msg in messages {
        if msg.role() != MessageRole::Tool && !pending_repairs.is_empty() {
            flush_repairs(&mut repaired, &mut pending_repairs, &mut repair_count);
        }
        repaired.push(msg.clone());
        match msg.role() {
            MessageRole::Assistant => {
                queue_assistant_repairs(msg, &mut pending_repairs);
            }
            MessageRole::Tool => {
                acknowledge_tool_result(msg, &mut pending_repairs);
            }
            _ => {}
        }
    }
    if !pending_repairs.is_empty() {
        flush_repairs(&mut repaired, &mut pending_repairs, &mut repair_count);
    }
    Ok((repaired, repair_count))
}

fn queue_assistant_repairs(
    msg: &SessionMessage,
    pending: &mut Vec<(PersistedToolCallId, Option<PersistedToolName>)>,
) {
    if let Some(calls) = msg.tool_calls() {
        for call in calls {
            pending.push((call.id().clone(), Some(call.function().name().clone())));
        }
    }
}

fn acknowledge_tool_result(
    msg: &SessionMessage,
    pending: &mut Vec<(PersistedToolCallId, Option<PersistedToolName>)>,
) {
    if let Some(id) = msg.tool_call_id() {
        pending.retain(|(pending_id, _)| pending_id != id);
    }
}

fn flush_repairs(
    repaired: &mut Vec<SessionMessage>,
    pending: &mut Vec<(PersistedToolCallId, Option<PersistedToolName>)>,
    count: &mut usize,
) {
    for (id, name) in pending.drain(..) {
        let content = MessageContent::Text("outcome_unknown".to_owned());
        let msg = SessionMessage::tool_result(id, name, content);
        repaired.push(msg);
        *count = count.saturating_add(1);
    }
}
