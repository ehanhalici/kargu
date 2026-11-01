//! Native tool catalog, early admission and editor gate corpus; final gate only.
use kargu_core::{
    application::{
        ApplicationActor, ClaimIntent, Mode, RequestedWorkspace, RunHandle, RunSettings,
        ToolOutcome,
    },
    domain::{
        ApplicationId, ConfigRevision, ExecutionTimeout, PolicyRevision, ToolCallId, ToolCallLimit,
        ToolName, ToolSafetyLevel,
    },
    error::CoreError,
    history::Message,
    security::{
        EditorPresenter, EditorResource, EditorToolAdmission, ExecutionGate, PreparedEditorTool,
        ToolRegistry, ToolRoute, UserDecision, Workspace,
    },
};
use serde_json::json;
use std::time::Duration;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn intent(root: &std::path::Path, mode: Mode) -> Result<ClaimIntent, CoreError> {
    Ok(ClaimIntent {
        mode,
        workspace: RequestedWorkspace::try_from(root.to_path_buf())?,
        tool_limit: ToolCallLimit::try_from(1)?,
        timeout: ExecutionTimeout::try_from(Duration::from_secs(30))?,
        config_revision: ConfigRevision::try_from(3)?,
        policy_revision: PolicyRevision::try_from(7)?,
    })
}
fn settings(root: &std::path::Path, mode: Mode) -> Result<RunSettings, CoreError> {
    RunSettings::new(
        mode,
        Workspace::try_from(root.to_path_buf())?,
        ToolCallLimit::try_from(1)?,
        Duration::from_secs(30),
        ConfigRevision::try_from(3)?,
        PolicyRevision::try_from(7)?,
    )
}
fn model_call(
    actor: &mut ApplicationActor,
    run: &RunHandle,
    name: &str,
) -> Result<ToolCallId, Box<dyn std::error::Error>> {
    let message: Message = serde_json::from_value(json!({"role":"assistant", "tool_calls":[{
        "id":"provider-call", "type":"function", "function":{"name":name, "arguments":"{}"}
    }]}))?;
    actor.append_history(run, message)?;
    Ok(actor
        .session_history(run.scope().session_id())?
        .pending_calls()?
        .first()
        .ok_or("pending call")?
        .native_id
        .clone())
}
fn paused() -> Result<EditorResource, serde_json::Error> {
    serde_json::from_value(
        json!({"kind":"debugger", "connection_id":"debug-1", "stop_generation":2,
                                  "thread_id":1,"frame_id":0}),
    )
}

#[test]
fn builtin_catalog_keeps_alias_safety_modes_and_optional_editor_visibility() -> TestResult {
    let registry = ToolRegistry::builtins()?;
    let alias = ToolName::try_from("eval".to_owned())?;
    let eval = registry.resolve(&alias)?;
    assert_eq!(eval.name().as_str(), "debug_eval");
    assert_eq!(eval.safety(), ToolSafetyLevel::ExecutesArbitraryCode);
    assert!(eval.permits_mode(Mode::Debug));
    assert!(!eval.permits_mode(Mode::Ask));
    assert_eq!(
        eval.presentation().ok_or("presentation")?.route(),
        ToolRoute::Editor
    );
    let ask = registry.model_tools(Mode::Ask, &[])?;
    assert!(
        ask.iter()
            .any(|tool| tool["function"]["name"] == "read_file")
    );
    assert!(!ask.iter().any(|tool| tool["function"]["name"] == "bash"));
    let editor = vec![ToolName::try_from("debug_eval".to_owned())?];
    let debug = registry.model_tools(Mode::Debug, &editor)?;
    assert!(
        debug
            .iter()
            .any(|tool| tool["function"]["name"] == "debug_eval")
    );
    let read = registry.resolve(&ToolName::try_from("read_file".to_owned())?)?;
    let schema = read.presentation().ok_or("read schema")?.parameters();
    assert!(
        schema
            .validate(&json!({"file_path":"source.rs","from_line":1}))
            .is_ok()
    );
    assert!(
        schema
            .validate(&json!({"file_path":"source.rs","from_line":0}))
            .is_err()
    );
    assert!(
        schema
            .validate(&json!({"file_path":"source.rs","from_line":"1"}))
            .is_err()
    );
    Ok(())
}

#[test]
fn application_catalogs_are_isolated_and_a_claim_keeps_its_exact_catalog_on_activation()
-> TestResult {
    let root = tempfile::tempdir()?;
    let mut first_registry = ToolRegistry::standard()?;
    first_registry.register_process(ToolName::try_from("private_first".to_owned())?, vec![])?;
    let mut second_registry = ToolRegistry::standard()?;
    second_registry.register_process(ToolName::try_from("private_second".to_owned())?, vec![])?;
    let mut first = ApplicationActor::with_registry(ApplicationId::new(), first_registry);
    let second = ApplicationActor::with_registry(ApplicationId::new(), second_registry);
    let session = first.create_session();
    let claim = first.claim_run(&session, intent(root.path(), Mode::Agent)?)?;
    assert!(
        claim
            .tool_registry()
            .resolve(&ToolName::try_from("private_first".to_owned())?)
            .is_ok()
    );
    assert!(
        claim
            .tool_registry()
            .resolve(&ToolName::try_from("private_second".to_owned())?)
            .is_err()
    );
    assert!(
        second
            .tool_registry()
            .resolve(&ToolName::try_from("private_first".to_owned())?)
            .is_err()
    );
    let revision = claim.tool_registry().revision();
    let run = first.activate_claim(claim.prepare_workspace()?)?;
    assert!(std::ptr::eq(claim.tool_registry(), run.tool_registry()));
    assert_eq!(run.tool_registry().revision(), revision);
    // Internal execution helpers must never appear as model-visible tools.
    assert!(
        !run.tool_registry()
            .model_tools(Mode::Agent, &[])?
            .iter()
            .any(|tool| tool["function"]["name"] == "editor_edit")
    );
    first.cancel(&run)?;
    first.finish(&run)?;
    Ok(())
}

#[test]
fn claim_precedes_workspace_io_and_activation_preserves_the_original_owner() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut actor = ApplicationActor::new(ApplicationId::new());
    let session = actor.create_session();
    let absent = root.path().join("not-created");
    let failed = actor.claim_run(&session, intent(&absent, Mode::Agent)?)?;
    assert!(matches!(
        actor.claim_run(&session, intent(root.path(), Mode::Agent)?),
        Err(CoreError::Busy)
    ));
    assert!(failed.prepare_workspace().is_err());
    assert!(failed.drained());
    actor.finish_claim(&failed)?;
    let claim = actor.claim_run(&session, intent(root.path(), Mode::Agent)?)?;
    let original = claim.scope().clone();
    let prepared = claim.prepare_workspace()?;
    let run = actor.activate_claim(prepared)?;
    assert_eq!(&original, run.scope());
    assert!(claim.prepare_workspace().is_err());
    assert!(matches!(
        actor.finish_claim(&claim),
        Err(CoreError::StaleOwner)
    ));
    assert!(actor.validate(&run).is_ok());
    actor.cancel(&run)?;
    actor.finish(&run)?;
    Ok(())
}

#[test]
fn cancelled_claim_blocks_replacement_until_the_actual_preparation_resource_drops() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut actor = ApplicationActor::new(ApplicationId::new());
    let session = actor.create_session();
    let sibling = actor.create_session();
    let claim = actor.claim_run(&session, intent(root.path(), Mode::Agent)?)?;
    let child = claim.cancellation();
    let lease = claim.lease()?;
    let prepared = claim.prepare_workspace()?;
    assert!(matches!(
        actor.activate_claim(prepared),
        Err(CoreError::Busy)
    ));
    actor.cancel_claim(&claim)?;
    assert!(child.is_cancelled());
    assert!(matches!(actor.finish_claim(&claim), Err(CoreError::Busy)));
    assert!(matches!(
        actor.claim_run(&sibling, intent(root.path(), Mode::Agent)?),
        Err(CoreError::Busy)
    ));
    drop(lease);
    actor.finish_claim(&claim)?;
    let replacement = actor.claim_run(&sibling, intent(root.path(), Mode::Agent)?)?;
    assert!(matches!(
        actor.cancel_claim(&claim),
        Err(CoreError::StaleOwner)
    ));
    assert!(replacement.check_live().is_ok());
    actor.finish_claim(&replacement)?;
    Ok(())
}

#[test]
fn editor_rejection_can_commit_its_history_result_without_a_second_native_call() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut actor = ApplicationActor::new(ApplicationId::new());
    let session = actor.create_session();
    let run = actor.admit(&session, settings(root.path(), Mode::Debug)?)?;
    let native = model_call(&mut actor, &run, "eval")?;
    let registry = ToolRegistry::builtins()?;
    let provider = actor
        .session_history(&session)?
        .provider_id(&native)
        .ok_or("provider identity")?
        .clone();
    assert_eq!(
        actor.register_history_call(&run, &provider, &registry)?,
        native
    );
    let action = PreparedEditorTool::prepare(
        &run,
        &registry,
        &ToolName::try_from("eval".to_owned())?,
        native.clone(),
        json!({"expression":"synthetic_expression"}),
        paused()?,
    )?;
    let mut gate = ExecutionGate::default();
    let EditorToolAdmission::Review(review) =
        gate.prepare_editor_tool(&mut actor, &run, action, EditorPresenter::Available)?
    else {
        return Err("evaluation must require approval".into());
    };
    assert!(matches!(
        gate.decide_editor_tool(&mut actor, &run, &review, UserDecision::Rejected),
        Err(CoreError::Rejected)
    ));
    actor.complete_history_call(
        &run,
        &native,
        ToolOutcome::Rejected,
        "user rejected exact expression",
    )?;
    assert!(actor.session_history(&session)?.settled());
    assert!(
        gate.decide_editor_tool(&mut actor, &run, &review, UserDecision::Approved)
            .is_err()
    );
    let completion = actor.finish(&run)?;
    assert_eq!(completion.tool_results.len(), 1);
    assert_eq!(
        completion.tool_results.first().ok_or("result")?.outcome,
        ToolOutcome::Rejected
    );
    let history = actor.session_history(&session)?.snapshot();
    let result: serde_json::Value = serde_json::from_str(
        history
            .last()
            .ok_or("result message")?
            .message()
            .wire()
            .get(),
    )?;
    assert_eq!(result["name"], "eval");
    Ok(())
}

#[test]
fn issued_editor_read_retains_the_parent_until_actual_result_commit() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut actor = ApplicationActor::new(ApplicationId::new());
    let session = actor.create_session();
    let run = actor.admit(&session, settings(root.path(), Mode::Agent)?)?;
    let native = model_call(&mut actor, &run, "read_file_symbols")?;
    let registry = ToolRegistry::builtins()?;
    let provider = actor
        .session_history(&session)?
        .provider_id(&native)
        .ok_or("provider identity")?
        .clone();
    assert_eq!(
        actor.register_history_call(&run, &provider, &registry)?,
        native
    );
    let resource: EditorResource = serde_json::from_value(json!({"kind":"document",
        "document":{"path":"source.rs","document_id":"document-1","tick":1}}))?;
    let action = PreparedEditorTool::prepare(
        &run,
        &registry,
        &ToolName::try_from("read_file_symbols".to_owned())?,
        native,
        json!({"file_path":"source.rs"}),
        resource,
    )?;
    let mut gate = ExecutionGate::default();
    let EditorToolAdmission::Authorized(grant) =
        gate.prepare_editor_tool(&mut actor, &run, action, EditorPresenter::Missing)?
    else {
        return Err("safe read should use automatic policy".into());
    };
    let issued = grant.issue(&mut actor)?;
    assert!(!run.drained());
    actor.cancel(&run)?;
    assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
    issued.complete_history(&mut actor, ToolOutcome::Ok, "actual symbol result")?;
    assert!(run.drained());
    actor.finish(&run)?;
    assert!(actor.session_history(&session)?.settled());
    Ok(())
}
