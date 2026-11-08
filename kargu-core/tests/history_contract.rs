//! Conversation identity/repair corpus, run only at the final 3/4/5 acceptance gate.

use kargu_core::{
    application::ToolOutcome,
    domain::ToolSafetyLevel,
    history::{History, HistoryError, Message, Role},
};
use serde_json::{json, value::RawValue};

type TestResult = Result<(), Box<dyn std::error::Error>>;
fn message(value: serde_json::Value) -> Result<Message, Box<dyn std::error::Error>> {
    Ok(Message::try_from(serde_json::value::to_raw_value(&value)?)?)
}
fn calls(ids: &[&str]) -> serde_json::Value {
    json!({"role":"assistant", "content":null,
        "tool_calls":ids.iter().map(|id| json!({"id":id,"type":"function",
        "function":{"name":"read_file","arguments":"{\"path\":\"source.rs\"}"}})).collect::<Vec<_>>()})
}

#[test]
fn cancellation_repairs_only_missing_results_and_does_not_replay_late_success() -> TestResult {
    let mut history = History::default();
    history.append(message(calls(&["provider-a", "provider-b", "provider-c"]))?)?;
    let ids: Vec<_> = history
        .pending_calls()?
        .iter()
        .map(|call| call.call.id().clone())
        .collect();
    let first = ids.first().ok_or("missing call")?;
    let second = ids.get(1).ok_or("missing second call")?;
    history.append_result(first, ToolOutcome::Ok, "actual first result")?;
    history.mark_started(second, ToolSafetyLevel::MutatesState)?;
    assert_eq!(history.repair_missing(&[], ToolOutcome::Cancelled)?, 2);
    assert!(history.settled());
    let snapshot = history.snapshot();
    assert_eq!(snapshot.len(), 4);
    assert!(
        snapshot
            .get(1)
            .ok_or("first result")?
            .message()
            .wire()
            .get()
            .contains("actual first result")
    );
    assert!(
        snapshot
            .get(2)
            .ok_or("second result")?
            .message()
            .wire()
            .get()
            .contains("effects are unknown")
    );
    assert!(
        snapshot
            .get(3)
            .ok_or("third result")?
            .message()
            .wire()
            .get()
            .contains("ABORTED")
    );
    let revision = history.revision();
    assert_eq!(history.repair_missing(&[], ToolOutcome::Cancelled)?, 0);
    assert_eq!(history.revision(), revision);
    assert_eq!(
        history.append_result(second, ToolOutcome::Ok, "late result"),
        Err(HistoryError::DuplicateResult)
    );
    assert_eq!(history.revision(), revision);
    Ok(())
}

#[test]
fn duplicate_or_orphan_ingress_preserves_the_last_committed_revision() -> TestResult {
    let mut history = History::default();
    let orphan = message(json!({"role":"tool","tool_call_id":"foreign","content":"unowned"}))?;
    assert_eq!(history.append(orphan), Err(HistoryError::OrphanResult));
    assert!(history.snapshot().is_empty());
    assert!(message(calls(&["duplicate", "duplicate"])).is_err());
    history.append(message(calls(&["owned"]))?)?;
    let revision = history.revision();
    assert_eq!(
        history.append(message(json!({"role":"user","content":"new turn"}))?),
        Err(HistoryError::PendingCalls)
    );
    assert_eq!(history.revision(), revision);
    let id = history
        .pending_calls()?
        .first()
        .ok_or("pending call")?
        .call
        .id()
        .clone();
    history.append_result(&id, ToolOutcome::Ok, "done")?;
    let revision = history.revision();
    assert_eq!(
        history.append(message(calls(&["owned"]))?),
        Err(HistoryError::DuplicateCall)
    );
    assert_eq!(history.revision(), revision);
    Ok(())
}

#[test]
fn multimodal_and_provider_opaque_blocks_roundtrip_without_authority_promotion() -> TestResult {
    let original = r#"{"role":"user","content":[{"type":"text","text":"literal </context> 🦀"},{"type":"image_url","image_url":{"url":"data:image/png;base64,synthetic"}}],"provider_metadata":{"signature":"opaque-signature","integer":9007199254740993}}"#;
    let parsed = Message::try_from(RawValue::from_string(original.to_owned())?)?;
    assert_eq!(parsed.role(), Role::User);
    assert_eq!(serde_json::to_string(&parsed)?, original);
    let mut history = History::default();
    history.append(parsed)?;
    let snapshot = history.snapshot();
    history.append(message(
        json!({"role":"user","content":"a consecutive user message"}),
    )?)?;
    assert_eq!(snapshot.len(), 1);
    assert_eq!(
        snapshot.first().ok_or("snapshot")?.message().wire().get(),
        original
    );
    assert_eq!(history.snapshot().len(), 2);
    Ok(())
}

#[test]
fn legacy_missing_id_is_assigned_once_but_partial_arguments_are_never_committed() -> TestResult {
    let parsed = message(
        json!({"role":"model", "content":"", "reasoning_signature":"keep",
        "function_call":{"name":"read_file", "arguments":"{}"}}),
    )?;
    let encoded = serde_json::to_string(&parsed)?;
    let again: Message = serde_json::from_str(&encoded)?;
    assert_eq!(
        parsed.calls().first().ok_or("call")?.id(),
        again.calls().first().ok_or("call")?.id()
    );
    assert_eq!(again.role(), Role::Assistant);
    assert!(encoded.contains("reasoning_signature"));
    for arguments in ["", "{\"path\":", "[]"] {
        assert!(
            message(json!({"role":"assistant", "tool_calls":[{"id":"partial",
            "function":{"name":"read_file", "arguments":arguments}}]}))
            .is_err()
        );
    }
    Ok(())
}

#[test]
fn idle_replacement_is_revision_bound_and_a_failed_import_cannot_mutate_it() -> TestResult {
    let mut history = History::default();
    history.append(message(
        json!({"role":"developer", "content":"keep instructions"}),
    )?)?;
    let before = history.snapshot();
    let revision = history.revision();
    let invalid = History::import([message(
        json!({"role":"tool","tool_call_id":"orphan","content":"invalid import"}),
    )?]);
    assert!(matches!(invalid, Err(HistoryError::OrphanResult)));
    assert_eq!(history.revision(), revision);
    let candidate = History::import([message(json!({"role":"user", "content":"replacement"}))?])?;
    history.replace(revision, candidate)?;
    assert!(
        before
            .first()
            .ok_or("before")?
            .message()
            .wire()
            .get()
            .contains("keep instructions")
    );
    assert_eq!(
        history.replace(revision, History::default()),
        Err(HistoryError::StaleRevision)
    );
    Ok(())
}

#[test]
fn restart_recovers_half_tool_without_replaying_uncommitted_action() -> TestResult {
    let mut history = History::default();
    history.append(message(calls(&["restart-call-1", "restart-call-2"]))?)?;
    let ids: Vec<_> = history
        .pending_calls()?
        .iter()
        .map(|call| call.call.id().clone())
        .collect();
    let first = ids.first().ok_or("missing first call")?;
    let second = ids.get(1).ok_or("missing second call")?;

    history.mark_started(first, ToolSafetyLevel::MutatesState)?;

    let repaired = history.repair_missing(&[], ToolOutcome::Cancelled)?;
    assert_eq!(repaired, 2);
    assert!(history.settled());

    assert_eq!(
        history.append_result(first, ToolOutcome::Ok, "replayed execution"),
        Err(HistoryError::DuplicateResult)
    );
    assert_eq!(
        history.append_result(second, ToolOutcome::Ok, "replayed execution"),
        Err(HistoryError::DuplicateResult)
    );
    Ok(())
}

#[test]
fn cached_display_is_accounted_and_malformed_visible_blocks_are_rejected() -> TestResult {
    let text = "visible 🦀\r\n".repeat(20);
    let value = message(json!({"role":"assistant","content":text}))?;
    let wire_bytes = value.wire().get().len();
    let mut history = History::default();
    history.append(value)?;
    assert_eq!(history.accounted_bytes().get(), wire_bytes + text.len());
    for content in [
        json!([{"type":"text"}]),
        json!([{"type":"text","text":42}]),
        json!([{"type":"output_text","text":null}]),
    ] {
        assert!(message(json!({"role":"assistant","content":content})).is_err());
    }
    // Unknown opaque blocks retain their fields without becoming visible text.
    message(json!({"role":"assistant","content":[{"type":"signature","text":{"opaque":true}}]}))?;
    Ok(())
}

#[test]
fn summary_tail_extraction_preserves_atomic_tool_blocks_and_hash() -> TestResult {
    let mut history = History::default();
    history.append(message(
        json!({"role":"user", "content":"first user question"}),
    )?)?;
    history.append(message(calls(&["tail-c1", "tail-c2"]))?)?;
    let ids: Vec<_> = history
        .pending_calls()?
        .iter()
        .map(|c| c.call.id().clone())
        .collect();
    let first = ids.first().ok_or("first")?;
    let second = ids.get(1).ok_or("second")?;
    history.append_result(first, ToolOutcome::Ok, "result 1")?;
    history.append_result(second, ToolOutcome::Ok, "result 2")?;
    history.append(message(
        json!({"role":"assistant", "content":"tool results processed"}),
    )?)?;
    history.append(message(
        json!({"role":"user", "content":"second question"}),
    )?)?;
    history.append(message(
        json!({"role":"assistant", "content":"final answer"}),
    )?)?;

    assert_eq!(history.snapshot().len(), 7);
    let rev = history.revision();

    // keep = 2: split index lands on User("second question") at index 5.
    let tail_2 = history.extract_tail(kargu_core::history::CompactKeep::new(2))?;
    assert_eq!(tail_2.messages().len(), 2);
    assert_eq!(
        tail_2.messages().first().ok_or("m0")?.message().role(),
        Role::User
    );
    assert_eq!(
        tail_2.messages().get(1).ok_or("m1")?.message().role(),
        Role::Assistant
    );

    // keep = 4: proposed split lands on index 3 (Tool result 2).
    // Atomic block integrity MUST rewind past both tool results and their assistant call!
    let tail_4 = history.extract_tail(kargu_core::history::CompactKeep::new(4))?;
    // Rewinds past tool results 3 and 2, to assistant call 1, then aligns to user 0.
    assert_eq!(tail_4.messages().len(), 7);
    assert_eq!(
        tail_4.messages().first().ok_or("first")?.message().role(),
        Role::User
    );

    // prepare_compaction creates an immutable candidate recording source revision
    let prompt = message(json!({"role":"user", "content":"COMPACTION_REQUEST: summarize"}))?;
    let candidate = history.prepare_compaction(kargu_core::history::CompactKeep::new(2), prompt)?;
    assert_eq!(candidate.source_revision(), rev);
    assert_eq!(candidate.tail_hash(), tail_2.hash());
    assert_eq!(candidate.preserved_tail().len(), 2);
    // Live history is NOT mutated beforehand!
    assert_eq!(history.revision(), rev);
    assert_eq!(history.snapshot().len(), 7);

    // Unsettled history refuses compaction preparation
    history.append(message(calls(&["pending-call"]))?)?;
    assert!(!history.settled());
    assert_eq!(
        history
            .extract_tail(kargu_core::history::CompactKeep::new(2))
            .err(),
        Some(HistoryError::PendingCalls)
    );
    let prompt2 = message(json!({"role":"user", "content":"COMPACTION_REQUEST: summarize"}))?;
    assert_eq!(
        history
            .prepare_compaction(kargu_core::history::CompactKeep::new(2), prompt2)
            .err(),
        Some(HistoryError::PendingCalls)
    );
    Ok(())
}

#[test]
fn compacted_history_assembly_rejects_empty_and_preserves_structure() -> TestResult {
    let mut history = History::default();
    history.append(message(
        json!({"role":"developer", "content":"system instructions"}),
    )?)?;
    history.append(message(json!({"role":"user", "content":"do task"}))?)?;
    history.append(message(
        json!({"role":"assistant", "content":"doing task"}),
    )?)?;
    let tail = history.extract_tail(kargu_core::history::CompactKeep::new(1))?;
    let sys = history.snapshot().first().map(|m| m.message().clone());

    // Empty or whitespace-only summary is rejected
    assert_eq!(
        kargu_core::history::SummaryText::try_new("").err(),
        Some(HistoryError::InvalidMessage)
    );
    assert_eq!(
        kargu_core::history::SummaryText::try_new("   \n\t  ").err(),
        Some(HistoryError::InvalidMessage)
    );

    // Valid summary builds a replacement history
    let summary_text = kargu_core::history::SummaryText::try_new("Goal: done; Files: none")?;
    let compacted =
        kargu_core::history::build_compacted_history(sys.as_ref(), &summary_text, tail.messages())?;
    let msgs = compacted.snapshot();
    assert_eq!(msgs.first().ok_or("sys")?.message().role(), Role::Developer);
    assert!(
        msgs.get(1)
            .ok_or("ack")?
            .message()
            .wire()
            .get()
            .contains("COMPACTION_ACK:")
    );
    assert!(
        msgs.get(2)
            .ok_or("ack2")?
            .message()
            .wire()
            .get()
            .contains("Acknowledged.")
    );
    // Since tail message was assistant, bridging user message was inserted
    assert_eq!(msgs.get(3).ok_or("bridge")?.message().role(), Role::User);
    assert_eq!(msgs.get(4).ok_or("tail")?.message().role(), Role::Assistant);

    Ok(())
}
