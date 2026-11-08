//! Native actor lifecycle corpus. Run only at the final combined acceptance gate.

use kargu_core::{
    application::{
        ApplicationActor, Mode, RunHandle, RunSettings, ToolOutcome,
        agent::{
            AgentOptions, AgentPhase, AgentStop, AgentTool, AssistantTurn, ContinuationReason,
            ModelTurnLimit, ToolAdmission, ToolRefusal,
        },
    },
    domain::{ApplicationId, ConfigRevision, PolicyRevision, ToolCallLimit, ToolName},
    error::CoreError,
    history::Message,
    security::{
        EditorPresenter, EditorResource, EditorToolAdmission, ExecutionGate, PreparedEditorTool,
        ToolRegistry, UserDecision, Workspace,
    },
};
use serde_json::{Value, json};
use std::time::Duration;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn start(
    tools: bool,
    turns: u32,
) -> Result<(tempfile::TempDir, ApplicationActor, RunHandle), Box<dyn std::error::Error>> {
    start_mode(Mode::Agent, tools, turns)
}
fn start_mode(
    mode: Mode,
    tools: bool,
    turns: u32,
) -> Result<(tempfile::TempDir, ApplicationActor, RunHandle), Box<dyn std::error::Error>> {
    let root = tempfile::tempdir()?;
    let mut actor =
        ApplicationActor::with_registry(ApplicationId::new(), ToolRegistry::standard()?);
    let session = actor.create_session();
    let settings = RunSettings::new(
        mode,
        Workspace::try_from(root.path().to_path_buf())?,
        ToolCallLimit::try_from(16)?,
        Duration::from_secs(30),
        ConfigRevision::try_from(3)?,
        PolicyRevision::try_from(7)?,
    )?;
    let run = actor.admit(&session, settings)?;
    let prompt: Message =
        serde_json::from_value(json!({"role":"user", "content":"Inspect the current buffer"}))?;
    actor.start_agent(
        &run,
        AgentOptions {
            turn_limit: ModelTurnLimit::try_from(turns)?,
            tools_enabled: tools,
            editor_available: vec![ToolName::try_from("read_file_symbols".to_owned())?],
        },
        Some(prompt),
    )?;
    Ok((root, actor, run))
}
fn response(message: Value, finish: &str) -> Result<AssistantTurn, CoreError> {
    let raw = serde_json::value::to_raw_value(
        &json!({"choices":[{"message":message,"finish_reason":finish}]}),
    )
    .map_err(|_| CoreError::InvalidToolOutput)?;
    AssistantTurn::try_from(raw)
}
fn calls(ids: &[(&str, &str, &str)]) -> Value {
    json!({"role":"assistant", "content":null, "tool_calls": ids.iter().map(|(id,name,args)|
        json!({"id":id,"type":"function","function":{"name":name,"arguments":args}})).collect::<Vec<_>>()})
}
fn issue_symbols(
    actor: &mut ApplicationActor,
    tool: &AgentTool,
    gate: &mut ExecutionGate,
) -> Result<kargu_core::security::IssuedEditorTool, Box<dyn std::error::Error>> {
    let resource: EditorResource = serde_json::from_value(json!({"kind":"document",
        "document":{"path":"source.el","document_id":"buffer-1","tick":4}}))?;
    let action = PreparedEditorTool::prepare(
        tool.run(),
        tool.run().tool_registry(),
        tool.name(),
        tool.id().clone(),
        serde_json::from_str(tool.arguments().get())?,
        resource,
    )?;
    let EditorToolAdmission::Authorized(grant) =
        gate.prepare_editor_tool(actor, tool.run(), action, EditorPresenter::Missing)?
    else {
        return Err("inspection unexpectedly requested mutation consent".into());
    };
    Ok(grant.issue(actor)?)
}

#[test]
fn native_agent_serializes_model_batch_gate_results_and_next_turn_under_one_owner() -> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    let model = actor.begin_model_turn(&run)?;
    assert!(!model.tools().is_empty());
    assert_eq!(model.messages().len(), 1);
    let payload: Value = serde_json::from_str(
        model
            .canonical_payload(
                &kargu_core::api::ModelId::try_from("captured-model".to_owned())?,
                true,
            )?
            .get(),
    )?;
    assert_eq!(payload["model"], "captured-model");
    assert_eq!(payload["stream"], true);
    assert_eq!(payload["messages"].as_array().ok_or("messages")?.len(), 1);
    assert!(matches!(actor.begin_model_turn(&run), Err(CoreError::Busy)));
    let foreign_write: Message =
        serde_json::from_value(json!({"role":"user","content":"overtake"}))?;
    assert!(matches!(
        actor.append_history(&run, foreign_write),
        Err(CoreError::Rejected)
    ));
    assert_eq!(
        model.complete(
            &mut actor,
            response(
                calls(&[
                    (
                        "provider-a",
                        "read_file_symbols",
                        "{\"file_path\":\"source.el\"}"
                    ),
                    ("provider-b", "absent_extension", "{}"),
                ]),
                "tool_calls"
            )?
        )?,
        AgentPhase::Tools
    );
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    let tool = actor.next_agent_tool(&run)?;
    assert_eq!(tool.name().as_str(), "read_file_symbols");
    assert!(matches!(actor.next_agent_tool(&run), Err(CoreError::Busy)));
    assert!(matches!(actor.begin_model_turn(&run), Err(CoreError::Busy)));
    let mut gate = ExecutionGate::default();
    issue_symbols(&mut actor, &tool, &mut gate)?.complete(&mut actor, ToolOutcome::Ok)?;
    tool.complete(&mut actor, ToolOutcome::Ok, "actual symbols")?;
    let unknown = actor.next_agent_tool(&run)?;
    assert_eq!(
        unknown.admission(),
        ToolAdmission::Refused(ToolRefusal::Unavailable)
    );
    unknown.complete(&mut actor, ToolOutcome::Failed, "tool unavailable")?;
    let next = actor.begin_model_turn(&run)?;
    assert_eq!(next.messages().len(), 4);
    assert_eq!(
        next.complete(
            &mut actor,
            response(json!({"role":"assistant","content":"Inspected."}), "stop")?
        )?,
        AgentPhase::Terminal(AgentStop::Answer)
    );
    assert!(matches!(actor.begin_model_turn(&run), Err(CoreError::Busy)));
    let done = actor.finish(&run)?;
    assert_eq!(done.tool_results().len(), 2);
    assert!(actor.session_history(run.scope().session_id())?.settled());
    Ok(())
}

#[test]
fn cancelled_model_cannot_publish_but_its_ticket_blocks_release_until_actual_join() -> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    let model = actor.begin_model_turn(&run)?;
    let before = actor.session_history(run.scope().session_id())?.revision();
    actor.cancel(&run)?;
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    assert!(matches!(
        model.complete(
            &mut actor,
            response(json!({"role":"assistant","content":"late"}), "stop")?
        ),
        Err(CoreError::Cancelled)
    ));
    assert!(run.drained());
    assert_eq!(
        actor.session_history(run.scope().session_id())?.revision(),
        before
    );
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn issued_tool_reports_facts_after_cancel_and_never_replays_the_call() -> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    actor.begin_model_turn(&run)?.complete(
        &mut actor,
        response(
            calls(&[(
                "provider-a",
                "read_file_symbols",
                "{\"file_path\":\"source.el\"}",
            )]),
            "tool_calls",
        )?,
    )?;
    let tool = actor.next_agent_tool(&run)?;
    let mut gate = ExecutionGate::default();
    let issued = issue_symbols(&mut actor, &tool, &mut gate)?;
    actor.cancel(&run)?;
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    issued.complete(&mut actor, ToolOutcome::Ok)?;
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    tool.complete(
        &mut actor,
        ToolOutcome::Ok,
        "actual observation before teardown",
    )?;
    let result = actor.finish(&run)?;
    assert_eq!(
        result.tool_results().first().ok_or("result")?.outcome,
        ToolOutcome::Ok
    );
    assert!(actor.session_history(run.scope().session_id())?.settled());
    Ok(())
}

#[test]
fn dropping_an_unissued_tool_repairs_only_its_missing_result_after_cancellation() -> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    actor.begin_model_turn(&run)?.complete(
        &mut actor,
        response(
            calls(&[(
                "provider-a",
                "read_file_symbols",
                "{\"file_path\":\"source.el\"}",
            )]),
            "tool_calls",
        )?,
    )?;
    let tool = actor.next_agent_tool(&run)?;
    actor.cancel(&run)?;
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    drop(tool);
    let result = actor.finish(&run)?;
    assert_eq!(
        result.tool_results().first().ok_or("result")?.outcome,
        ToolOutcome::Cancelled
    );
    assert!(actor.session_history(run.scope().session_id())?.settled());
    Ok(())
}

#[test]
fn repeated_semantic_arguments_need_a_separate_decision_before_the_shared_gate() -> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    let mut gate = ExecutionGate::default();
    for (index, arguments) in [
        "{\"file_path\":\"source.el\"}",
        "{ \"file_path\" : \"source.el\" }",
        "{\"file_path\":\"source.el\"}",
    ]
    .iter()
    .enumerate()
    {
        let id = format!("provider-{index}");
        actor.begin_model_turn(&run)?.complete(
            &mut actor,
            response(
                calls(&[(&id, "read_file_symbols", arguments)]),
                "tool_calls",
            )?,
        )?;
        let mut tool = actor.next_agent_tool(&run)?;
        if index == 2 {
            assert_eq!(tool.admission(), ToolAdmission::Repetition);
            assert!(issue_symbols(&mut actor, &tool, &mut gate).is_err());
            tool = tool.decide_repetition(&mut actor, UserDecision::Approved)?;
        }
        assert_eq!(tool.admission(), ToolAdmission::Ready);
        issue_symbols(&mut actor, &tool, &mut gate)?.complete(&mut actor, ToolOutcome::Ok)?;
        tool.complete(&mut actor, ToolOutcome::Ok, "actual symbols")?;
    }
    actor.cancel(&run)?;
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn disabled_tools_and_mode_schema_refusals_still_settle_the_provider_protocol() -> TestResult {
    for (enabled, name, arguments, refusal) in [
        (
            false,
            "read_file",
            "{\"file_path\":\"source.el\"}",
            ToolRefusal::Disabled,
        ),
        (
            true,
            "read_file",
            "{\"file_path\":\"source.el\",\"from_line\":0}",
            ToolRefusal::Arguments,
        ),
        (
            true,
            "debug_eval",
            "{\"expression\":\"synthetic\"}",
            ToolRefusal::Unavailable,
        ),
    ] {
        let (_root, mut actor, run) = start(enabled, 4)?;
        let model = actor.begin_model_turn(&run)?;
        assert_eq!(model.tools().is_empty(), !enabled);
        if !enabled {
            let payload: Value = serde_json::from_str(
                model
                    .canonical_payload(
                        &kargu_core::api::ModelId::try_from("captured-model".to_owned())?,
                        false,
                    )?
                    .get(),
            )?;
            assert!(payload.get("tools").is_none());
            assert!(payload.get("tool_choice").is_none());
        }
        model.complete(
            &mut actor,
            response(calls(&[("provider-a", name, arguments)]), "tool_calls")?,
        )?;
        let tool = actor.next_agent_tool(&run)?;
        assert_eq!(tool.admission(), ToolAdmission::Refused(refusal));
        tool.complete(&mut actor, ToolOutcome::Rejected, "typed refusal")?;
        assert!(actor.session_history(run.scope().session_id())?.settled());
        actor.cancel(&run)?;
        actor.finish(&run)?;
    }
    Ok(())
}

#[test]
fn ask_mode_hides_bash_and_also_rejects_a_provider_that_calls_it_anyway() -> TestResult {
    let (_root, mut actor, run) = start_mode(Mode::Ask, true, 4)?;
    let model = actor.begin_model_turn(&run)?;
    assert!(
        !model
            .tools()
            .iter()
            .any(|tool| tool["function"]["name"] == "bash")
    );
    model.complete(
        &mut actor,
        response(
            calls(&[("provider-a", "bash", "{\"command\":\"printf synthetic\"}")]),
            "tool_calls",
        )?,
    )?;
    let tool = actor.next_agent_tool(&run)?;
    assert_eq!(tool.admission(), ToolAdmission::Refused(ToolRefusal::Mode));
    tool.complete(&mut actor, ToolOutcome::Rejected, "mode forbids execution")?;
    assert!(actor.session_history(run.scope().session_id())?.settled());
    actor.cancel(&run)?;
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn thought_continuation_keeps_turn_charges_and_requires_explicit_cap_extension() -> TestResult {
    let (_root, mut actor, run) = start(true, 1)?;
    actor.begin_model_turn(&run)?.complete(&mut actor, response(json!({"role":"assistant", "content":"",
        "reasoning_content":"internal thought", "_kargu_opaque_content":[{"type":"thinking","signature":"opaque_signature"}]}), "stop")?)?;
    assert!(matches!(
        actor.continue_agent(&run, ContinuationReason::Empty),
        Err(CoreError::StaleOwner)
    ));
    actor.continue_agent(&run, ContinuationReason::ThoughtOnly)?;
    assert!(matches!(
        actor.begin_model_turn(&run),
        Err(CoreError::Limit)
    ));
    actor.extend_agent_turns(&run, ModelTurnLimit::try_from(2)?)?;
    let next = actor.begin_model_turn(&run)?;
    assert!(
        next.messages().iter().any(|message| message
            .message()
            .wire()
            .get()
            .contains("opaque_signature"))
    );
    next.complete(
        &mut actor,
        response(json!({"role":"assistant","content":"answer"}), "stop")?,
    )?;
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn partial_or_length_truncated_calls_cannot_become_executable_history() -> TestResult {
    for (message, reason) in [
        (
            calls(&[("provider-a", "read_file", "{\"file_path\":")]),
            "tool_calls",
        ),
        (
            calls(&[("provider-a", "read_file", "{\"file_path\":\"source.el\"}")]),
            "length",
        ),
        (json!({"role":"assistant","content":null}), "tool_calls"),
        (
            json!({"role":"tool","tool_call_id":"provider-a","content":"foreign"}),
            "stop",
        ),
    ] {
        assert!(response(message, reason).is_err());
    }
    let (_root, mut actor, run) = start(true, 4)?;
    actor.begin_model_turn(&run)?.complete(
        &mut actor,
        response(
            calls(&[(
                "provider-a",
                "read_file_symbols",
                "{\"file_path\":\"source.el\"}",
            )]),
            "tool_calls",
        )?,
    )?;
    let tool = actor.next_agent_tool(&run)?;
    assert!(matches!(
        tool.complete(&mut actor, ToolOutcome::Ok, "unissued false success"),
        Err(CoreError::Rejected)
    ));
    actor.cancel(&run)?;
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn mode_transitions_during_active_run_are_rejected_and_captured_policy_is_immutable() -> TestResult
{
    let (_root, mut actor, run) = start_mode(Mode::Ask, true, 4)?;
    let session = run.scope().session_id().clone();

    // An active run freezes its mode in RunSettings
    assert_eq!(run.mode(), Mode::Ask);

    // Attempting to change mode while a run is active is rejected with CoreError::Busy
    let intent = kargu_core::application::mode::ModeIntent::new(
        Mode::Agent,
        kargu_core::application::mode::DebugReady::new(false),
    );
    let busy = actor.commit_session_mode(
        &session,
        kargu_core::application::mode::ModeRevision::ZERO,
        intent,
    );
    assert!(matches!(busy, Err(CoreError::Busy)));

    // The active run mode remains Ask
    assert_eq!(run.mode(), Mode::Ask);

    // Complete the run
    let model = actor.begin_model_turn(&run)?;
    model.complete(
        &mut actor,
        response(json!({"role":"assistant","content":"Answer"}), "stop")?,
    )?;
    actor.finish(&run)?;

    // Now that run is finished and idle, mode transition succeeds
    let agent_intent = kargu_core::application::mode::ModeIntent::new(
        Mode::Agent,
        kargu_core::application::mode::DebugReady::new(false),
    );
    let committed = actor.commit_session_mode(
        &session,
        kargu_core::application::mode::ModeRevision::ZERO,
        agent_intent,
    )?;
    assert_eq!(committed.mode(), Mode::Agent);
    assert_eq!(
        committed.revision(),
        kargu_core::application::mode::ModeRevision::try_from(1)?
    );

    // The old finished run's captured settings mode is still Mode::Ask (immutable)
    assert_eq!(run.mode(), Mode::Ask);
    Ok(())
}

#[test]
fn plan_claim_during_active_run_is_rejected_and_single_use_is_enforced() -> TestResult {
    let (_root, mut actor, run) = start_mode(Mode::Plan, true, 4)?;
    let session = run.scope().session_id().clone();

    // Create a plan for this session
    let plan = actor.create_session_plan(
        &session,
        kargu_core::application::plan::PlanText::try_from("1. Plan action")?,
    )?;
    let plan_id = plan.id().clone();
    let rev = plan.revision();
    let hash = plan.content_hash();

    // While a run is active, claim is rejected with CoreError::Busy
    let intent = kargu_core::application::plan::PlanClaimIntent::new(rev, hash);
    assert!(matches!(
        actor.claim_session_plan(&session, &plan_id, intent),
        Err(CoreError::Busy)
    ));

    // Cancel and finish the active run
    actor.cancel(&run)?;
    actor.finish(&run)?;

    // Now claim succeeds
    let claimed = actor.claim_session_plan(&session, &plan_id, intent)?;
    assert_eq!(
        claimed.state(),
        kargu_core::application::plan::PlanState::Dispatching
    );

    // Second claim fails with AlreadyCompleted
    assert!(matches!(
        actor.claim_session_plan(&session, &plan_id, intent),
        Err(CoreError::AlreadyCompleted)
    ));

    Ok(())
}

#[test]
fn summary_turn_uses_existing_run_without_mutating_history_and_permits_only_one_compaction()
-> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    let session = run.scope().session_id().clone();
    let (initial_rev, initial_messages) = actor.history_snapshot(&session)?;
    assert_eq!(initial_messages.len(), 1);

    let prompt: Message = serde_json::from_value(json!({
        "role": "user",
        "content": "COMPACTION_REQUEST: summarize previous context"
    }))?;

    // 1. Begin summary turn on existing run
    let summary =
        actor.begin_summary_turn(&run, kargu_core::history::CompactKeep::new(8), prompt)?;
    assert_eq!(summary.history_revision(), initial_rev);
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Summary);

    // 2. Candidate captures source revision and preserved tail
    let candidate = summary.candidate();
    assert_eq!(candidate.source_revision(), initial_rev);
    assert_eq!(candidate.preserved_tail().len(), 1);

    // 3. Live history is NOT mutated beforehand!
    let (live_rev, live_messages) = actor.history_snapshot(&session)?;
    assert_eq!(live_rev, initial_rev);
    assert_eq!(live_messages.len(), 1);

    // 4. Tools-off: canonical payload has no tools
    let payload: Value = serde_json::from_str(
        summary
            .canonical_payload(
                &kargu_core::api::ModelId::try_from("summarizer-model".to_owned())?,
                kargu_core::application::agent::PayloadStream::PLAIN,
            )?
            .get(),
    )?;
    assert!(payload.get("tools").is_none());
    assert!(payload.get("tool_choice").is_none());

    // 5. While summary is in flight, neither model turn nor second summary can start
    assert!(matches!(actor.begin_model_turn(&run), Err(CoreError::Busy)));
    let prompt2: Message = serde_json::from_value(json!({
        "role": "user",
        "content": "COMPACTION_REQUEST: second attempt"
    }))?;
    assert!(matches!(
        actor.begin_summary_turn(
            &run,
            kargu_core::history::CompactKeep::new(8),
            prompt2.clone()
        ),
        Err(CoreError::Busy)
    ));

    // 6. Abort summary turn restores Ready phase without modifying history
    summary.abort(&mut actor)?;
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Ready);
    let (after_abort_rev, after_abort_msgs) = actor.history_snapshot(&session)?;
    assert_eq!(after_abort_rev, initial_rev);
    assert_eq!(after_abort_msgs.len(), 1);

    // 7. Sadece bir compaction hakkı: second compaction turn is rejected with CoreError::Limit!
    assert!(matches!(
        actor.begin_summary_turn(&run, kargu_core::history::CompactKeep::new(8), prompt2),
        Err(CoreError::Limit)
    ));

    // 8. Normal model turn can still proceed under remaining turn budget
    let model = actor.begin_model_turn(&run)?;
    assert!(!model.tools().is_empty());
    assert_eq!(model.history_revision(), initial_rev);
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Model);

    Ok(())
}

#[test]
fn summary_commit_only_on_matching_revision_and_stale_or_empty_or_cancel_preserves_history()
-> TestResult {
    let (_root, mut actor, run) = start(true, 4)?;
    let session = run.scope().session_id().clone();
    let (initial_rev, initial_messages) = actor.history_snapshot(&session)?;
    assert_eq!(initial_messages.len(), 1);

    let prompt: Message = serde_json::from_value(json!({
        "role": "user",
        "content": "COMPACTION_REQUEST: summarize context"
    }))?;

    let summary =
        actor.begin_summary_turn(&run, kargu_core::history::CompactKeep::new(8), prompt)?;
    assert_eq!(summary.history_revision(), initial_rev);
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Summary);

    // 1. Empty summary is rejected at the domain boundary without mutating history
    assert!(matches!(
        kargu_core::history::SummaryText::try_new(""),
        Err(kargu_core::history::HistoryError::InvalidMessage)
    ));
    let (rev_after_empty, msgs_after_empty) = actor.history_snapshot(&session)?;
    assert_eq!(rev_after_empty, initial_rev);
    assert_eq!(msgs_after_empty.len(), 1);

    // 2. Whitespace summary is also rejected without mutating history
    assert!(matches!(
        kargu_core::history::SummaryText::try_new("   \n\t  "),
        Err(kargu_core::history::HistoryError::InvalidMessage)
    ));
    let (rev_after_ws, msgs_after_ws) = actor.history_snapshot(&session)?;
    assert_eq!(rev_after_ws, initial_rev);
    assert_eq!(msgs_after_ws.len(), 1);

    // 3. Successful commit: matching revision replaces history and transitions to Ready
    let valid_summary =
        kargu_core::history::SummaryText::try_new("Prior work: buffer inspection.")?;
    let committed_rev = summary.commit(&mut actor, &valid_summary)?;
    assert!(committed_rev.get() > initial_rev.get());
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Ready);

    let (compacted_rev, compacted_msgs) = actor.history_snapshot(&session)?;
    assert_eq!(compacted_rev, committed_rev);
    // Messages must contain: user COMPACTION_ACK, assistant Acknowledged, and tail
    assert!(compacted_msgs.iter().any(|m| {
        m.message().role() == kargu_core::history::Role::User
            && m.message()
                .wire()
                .get()
                .contains("COMPACTION_ACK: Prior work summary:")
    }));
    assert!(compacted_msgs.iter().any(|m| {
        m.message().role() == kargu_core::history::Role::Assistant
            && m.message()
                .wire()
                .get()
                .contains("Acknowledged. Continuing from the summary.")
    }));

    // 4. Stale summary turn: after commit, a second attempt with the same summary turn is rejected
    let replay_summary = kargu_core::history::SummaryText::try_new("Late replay of summary")?;
    assert!(matches!(
        summary.commit(&mut actor, &replay_summary),
        Err(CoreError::StaleOwner)
    ));
    let (rev_after_replay, msgs_after_replay) = actor.history_snapshot(&session)?;
    assert_eq!(rev_after_replay, committed_rev);
    assert_eq!(msgs_after_replay.len(), compacted_msgs.len());

    // 5. Normal model turn can immediately proceed from Ready state
    let next_model = actor.begin_model_turn(&run)?;
    assert_eq!(next_model.history_revision(), committed_rev);
    assert_eq!(actor.agent_phase(&run)?, AgentPhase::Model);

    // 6. Test late summary commit after run cancellation / stop:
    let (_root2, mut actor2, run2) = start(true, 4)?;
    let prompt2: Message = serde_json::from_value(json!({
        "role": "user",
        "content": "COMPACTION_REQUEST: summarize run2"
    }))?;
    let summary2 =
        actor2.begin_summary_turn(&run2, kargu_core::history::CompactKeep::new(8), prompt2)?;
    actor2.cancel(&run2)?;
    let late_summary = kargu_core::history::SummaryText::try_new("Late summary after cancel")?;
    assert!(matches!(
        summary2.commit(&mut actor2, &late_summary),
        Err(CoreError::Cancelled)
    ));

    Ok(())
}
