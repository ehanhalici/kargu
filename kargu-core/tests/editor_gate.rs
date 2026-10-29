//! Cross-owner consent, replay and resource lifetime at the shared editor gate.
use kargu_core::{
    application::{ApplicationActor, Mode, RunHandle, RunSettings, ToolOutcome},
    domain::{ApplicationId, ConfigRevision, PolicyRevision, ToolCallId, ToolCallLimit, ToolName},
    edit::{
        intent::{EditorAction, EditorActionInput, EditorFileInput},
        types::{CaptureDigest, EditText, EditorRevision, EditorSourceId, ReviewMode, SavePolicy},
    },
    error::CoreError,
    security::{
        CommandEnvironment, CommandInput, CommandSpec, EditorAdmission, EditorAdmissionInput,
        EditorApprovalRequest, EditorDecision, EditorPresenter, ExecutionGate, ToolRegistry,
        UserDecision, Workspace,
    },
};
use std::time::Duration;
type TestResult = Result<(), Box<dyn std::error::Error>>;
struct Fixture {
    directory: tempfile::TempDir,
    workspace: Workspace,
    actor: ApplicationActor,
    run: RunHandle,
    registry: ToolRegistry,
    gate: ExecutionGate,
}
impl Fixture {
    fn new(mode: Mode) -> Result<Self, CoreError> {
        let directory = tempfile::tempdir()?;
        let workspace = Workspace::try_from(directory.path().to_path_buf())?;
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let run = actor.admit(
            &session,
            RunSettings::new(
                mode,
                workspace.clone(),
                ToolCallLimit::default(),
                Duration::from_secs(600),
                ConfigRevision::try_from(3)?,
                PolicyRevision::try_from(7)?,
            )?,
        )?;
        let mut registry = ToolRegistry::default();
        registry.register_editor(name("edit_file")?, vec![name("edit_alias")?])?;
        registry.register_process(name("shell")?, vec![])?;
        Ok(Self {
            directory,
            workspace,
            actor,
            run,
            registry,
            gate: ExecutionGate::default(),
        })
    }
    fn input(&self, review_mode: ReviewMode, delete: bool) -> Result<EditorActionInput, CoreError> {
        let path = "source.txt".to_owned().try_into()?;
        let base = EditText::try_from("private original body".to_owned())?;
        let capture = CaptureDigest::try_from("a".repeat(64))?;
        let file = if delete {
            EditorFileInput::Delete {
                path,
                base: base.into(),
                capture,
            }
        } else {
            EditorFileInput::Update {
                path,
                base: base.into(),
                proposed: EditText::try_from("private proposed body".to_owned())?.into(),
                capture,
            }
        };
        Ok(EditorActionInput {
            source: EditorSourceId::try_from(
                "editor_source_03876e51-6f38-4496-8817-d17979d848aa".to_owned(),
            )?,
            revision: EditorRevision::try_from(1)?,
            workspace: self.workspace.clone(),
            config_revision: ConfigRevision::try_from(3)?,
            policy_revision: PolicyRevision::try_from(7)?,
            review_mode,
            save_policy: SavePolicy::BufferOnly,
            files: vec![file],
        })
    }
    fn admit(
        &mut self,
        input: EditorActionInput,
        presenter: EditorPresenter,
    ) -> Result<EditorAdmission, CoreError> {
        self.gate.admit_editor(
            &mut self.actor,
            &self.run,
            &self.registry,
            &name("edit_alias")?,
            EditorAdmissionInput {
                call_id: ToolCallId::new(),
                action: EditorAction::try_from(input)?,
                presenter,
            },
        )
    }
    fn review(&mut self, mode: ReviewMode) -> Result<EditorApprovalRequest, CoreError> {
        let input = self.input(mode, false)?;
        match self.admit(input, EditorPresenter::Available)? {
            EditorAdmission::Review(request) => Ok(request),
            _ => Err(CoreError::Rejected),
        }
    }
    fn decide(
        &mut self,
        request: &EditorApprovalRequest,
        decision: EditorDecision,
    ) -> Result<kargu_core::security::AuthorizedEditorEdit, CoreError> {
        self.gate.decide_editor(
            &mut self.actor,
            &self.run,
            request,
            request.revision(),
            decision,
        )
    }
}
fn name(value: &str) -> Result<ToolName, CoreError> {
    value.to_owned().try_into()
}

#[test]
fn auto_grant_holds_actual_run_until_explicit_unissued_cancellation() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    let input = f.input(ReviewMode::Auto, false)?;
    let EditorAdmission::Authorized(grant) = f.admit(input, EditorPresenter::Missing)? else {
        return Err("expected auto grant".into());
    };
    assert_eq!(f.gate.pending_count(), 0);
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::Busy)));
    let metadata = serde_json::to_string(grant.action().metadata())?;
    assert!(!metadata.contains("private original body"));
    assert!(!metadata.contains("private proposed body"));
    assert!(!f.directory.path().join("source.txt").exists());
    grant.revalidate(&f.actor)?;
    grant.cancel_unissued(&mut f.actor)?;
    let completion = f.actor.finish(&f.run)?;
    assert_eq!(completion.tool_results.len(), 1);
    assert_eq!(
        completion.tool_results.first().map(|r| r.outcome),
        Some(ToolOutcome::Cancelled)
    );
    Ok(())
}
#[test]
fn stale_revision_and_foreign_run_cannot_consume_consent_and_accept_is_single_use() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    let request = f.review(ReviewMode::Async)?;
    assert!(matches!(
        f.gate.decide_editor(
            &mut f.actor,
            &f.run,
            &request,
            EditorRevision::try_from(2)?,
            EditorDecision::Accept
        ),
        Err(CoreError::StaleOwner)
    ));
    let mut foreign = Fixture::new(Mode::Agent)?;
    assert!(matches!(
        f.gate.decide_editor(
            &mut foreign.actor,
            &foreign.run,
            &request,
            request.revision(),
            EditorDecision::Accept
        ),
        Err(CoreError::StaleOwner)
    ));
    assert_eq!(f.gate.pending_count(), 1);
    let grant = f.decide(&request, EditorDecision::Accept)?;
    assert!(matches!(
        f.decide(&request, EditorDecision::Accept),
        Err(CoreError::ApprovalUnavailable)
    ));
    grant.cancel_unissued(&mut f.actor)?;
    f.actor.finish(&f.run)?;
    Ok(())
}
#[test]
fn presenter_deletion_and_actual_mode_fail_before_creating_pending_work() -> TestResult {
    for mode in [Mode::Ask, Mode::Plan, Mode::Debug] {
        let mut f = Fixture::new(mode)?;
        let input = f.input(ReviewMode::Auto, false)?;
        assert!(matches!(
            f.admit(input, EditorPresenter::Available),
            Err(CoreError::Rejected)
        ));
        assert_eq!(f.gate.pending_count(), 0);
        assert!(f.actor.finish(&f.run)?.tool_results.is_empty());
    }
    for mode in [ReviewMode::Async, ReviewMode::Blocking] {
        let mut f = Fixture::new(Mode::Agent)?;
        let input = f.input(mode, false)?;
        assert!(matches!(
            f.admit(input, EditorPresenter::Missing),
            Err(CoreError::Unavailable)
        ));
        let input = f.input(mode, true)?;
        assert!(matches!(
            f.admit(input, EditorPresenter::Available),
            Err(CoreError::Rejected)
        ));
        assert_eq!(f.gate.pending_count(), 0);
        assert!(f.actor.finish(&f.run)?.tool_results.is_empty());
    }
    let mut f = Fixture::new(Mode::Agent)?;
    let input = f.input(ReviewMode::Auto, true)?;
    assert!(matches!(
        f.admit(input, EditorPresenter::Missing),
        Err(CoreError::Rejected)
    ));
    assert_eq!(f.gate.pending_count(), 0);
    let mut input = f.input(ReviewMode::Auto, true)?;
    input.save_policy = SavePolicy::Save;
    let EditorAdmission::Authorized(grant) = f.admit(input, EditorPresenter::Missing)? else {
        return Err("expected auto delete grant".into());
    };
    grant.cancel_unissued(&mut f.actor)?;
    f.actor.finish(&f.run)?;
    Ok(())
}
#[test]
fn root_capture_and_policy_config_are_bound_to_the_actual_native_run() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    for field in ["root", "config", "policy"] {
        let mut input = f.input(ReviewMode::Auto, false)?;
        match field {
            "root" => input.workspace = Workspace::try_from(f.directory.path().to_path_buf())?,
            "config" => input.config_revision = ConfigRevision::try_from(4)?,
            _ => input.policy_revision = PolicyRevision::try_from(8)?,
        }
        assert!(matches!(
            f.admit(input, EditorPresenter::Available),
            Err(CoreError::Rejected)
        ));
    }
    assert!(f.actor.finish(&f.run)?.tool_results.is_empty());
    Ok(())
}
#[test]
fn command_and_editor_share_one_pending_ledger_and_independent_decisions() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    let shell = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|p| p.join("sh"))
        .find(|p| p.is_file())
        .ok_or("sh unavailable")?;
    let command = CommandSpec::try_from(CommandInput {
        program: shell,
        arguments: vec!["-c".into(), "exit 0".into()],
        working_directory: f.directory.path().to_path_buf(),
        timeout: Some(Duration::from_secs(1)),
        environment: CommandEnvironment::default(),
    })?;
    let command_request = f.gate.prepare(
        &mut f.actor,
        &f.run,
        &f.registry,
        &name("shell")?,
        ToolCallId::new(),
        command,
    )?;
    let editor_request = f.review(ReviewMode::Blocking)?;
    assert_eq!(f.gate.pending_count(), 2);
    assert!(matches!(
        f.decide(&editor_request, EditorDecision::Reject),
        Err(CoreError::Rejected)
    ));
    assert_eq!(f.gate.pending_count(), 1);
    assert!(matches!(
        f.gate.decide(
            &mut f.actor,
            &f.run,
            &command_request,
            UserDecision::Rejected
        ),
        Err(CoreError::Rejected)
    ));
    let completion = f.actor.finish(&f.run)?;
    assert_eq!(completion.tool_results.len(), 2);
    assert!(
        completion
            .tool_results
            .iter()
            .all(|r| r.outcome == ToolOutcome::Rejected)
    );
    Ok(())
}
#[tokio::test(start_paused = true)]
async fn exact_deadline_and_revocation_release_only_through_shared_drain() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    let request = f.review(ReviewMode::Blocking)?;
    tokio::time::advance(
        request
            .deadline()
            .duration_since(tokio::time::Instant::now()),
    )
    .await;
    assert!(matches!(
        f.decide(&request, EditorDecision::Accept),
        Err(CoreError::ApprovalExpired)
    ));
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Timeout)
    );
    let mut f = Fixture::new(Mode::Agent)?;
    let request = f.review(ReviewMode::Async)?;
    f.actor.cancel(&f.run)?;
    assert!(f.decide(&request, EditorDecision::Accept).is_err());
    assert_eq!(f.gate.pending_count(), 1);
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::Busy)));
    f.gate.expire(&mut f.actor, &f.run)?;
    assert_eq!(f.gate.pending_count(), 0);
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Cancelled)
    );
    Ok(())
}
#[test]
fn interruption_is_terminal_and_duplicate_paths_never_enter_the_ledger() -> TestResult {
    let mut f = Fixture::new(Mode::Agent)?;
    let request = f.review(ReviewMode::Async)?;
    assert!(matches!(
        f.decide(&request, EditorDecision::Interrupt),
        Err(CoreError::Cancelled)
    ));
    assert!(matches!(
        f.decide(&request, EditorDecision::Accept),
        Err(CoreError::ApprovalUnavailable)
    ));
    let mut input = f.input(ReviewMode::Auto, false)?;
    input.files.extend(f.input(ReviewMode::Auto, false)?.files);
    assert!(EditorAction::try_from(input).is_err());
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Cancelled)
    );
    Ok(())
}
