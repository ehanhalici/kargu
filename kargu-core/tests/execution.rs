//! Typed admission, approval and real Linux process ownership regression cases.

use kargu_core::{
    application::{ApplicationActor, Mode, RunHandle, RunSettings, ToolOutcome},
    constants::limits,
    domain::*,
    error::CoreError,
    process::{
        CleanupPolicy, CleanupSettings, InputChunk, JobStatus, OutputStream, ProcessSupervisor,
    },
    security::{
        ApprovalRequest, AuthorizedCommand, CommandEnvironment, CommandInput, CommandSpec,
        ExecutionGate, ToolRegistry, UserDecision, Workspace,
    },
};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn development_environment_preserves_entries_without_removing_byte_bounds() -> TestResult {
    let mut environment = BTreeMap::new();
    for index in 0..limits::COMMAND_ENVIRONMENT_ENTRIES {
        environment.insert(
            OsString::from(format!("FIXTURE_{index}")),
            OsString::from("v"),
        );
    }
    CommandEnvironment::try_from(environment.clone())?;
    environment.insert(OsString::from("OVER_LIMIT"), OsString::from("v"));
    assert!(matches!(
        CommandEnvironment::try_from(environment),
        Err(CoreError::Limit)
    ));
    let oversized = BTreeMap::from([(
        OsString::from("ONE"),
        OsString::from("x".repeat(limits::COMMAND_BYTES)),
    )]);
    assert!(matches!(
        CommandEnvironment::try_from(oversized),
        Err(CoreError::Limit)
    ));
    Ok(())
}

struct Fixture {
    _directory: tempfile::TempDir,
    root: PathBuf,
    actor: ApplicationActor,
    session: SessionId,
    run: RunHandle,
    registry: ToolRegistry,
    gate: ExecutionGate,
    supervisor: ProcessSupervisor,
}
impl Fixture {
    fn new(mode: Mode, timeout: Duration) -> Result<Self, CoreError> {
        let directory = tempfile::tempdir()?;
        let root = directory.path().join("workspace");
        fs::create_dir(&root)?;
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let run = actor.admit(&session, settings(&root, mode, timeout)?)?;
        let mut registry = ToolRegistry::default();
        registry.register_process(name("bash")?, vec![name("terminal")?])?;
        let supervisor = ProcessSupervisor::new(CleanupPolicy::try_from(CleanupSettings {
            grace: Duration::from_millis(60),
            drain: Duration::from_secs(2),
        })?)?;
        Ok(Self {
            _directory: directory,
            root,
            actor,
            session,
            run,
            registry,
            gate: ExecutionGate::default(),
            supervisor,
        })
    }
    fn request(&mut self, script: &str, timeout: Duration) -> Result<ApprovalRequest, CoreError> {
        let command = command(&self.root, script, timeout)?;
        self.request_spec(command)
    }
    fn request_spec(&mut self, command: CommandSpec) -> Result<ApprovalRequest, CoreError> {
        self.gate.prepare(
            &mut self.actor,
            &self.run,
            &self.registry,
            &name("terminal")?,
            ToolCallId::new(),
            command,
        )
    }
    fn approve(&mut self, script: &str, timeout: Duration) -> Result<AuthorizedCommand, CoreError> {
        let request = self.request(script, timeout)?;
        self.gate
            .decide(&mut self.actor, &self.run, &request, UserDecision::Approved)
    }
    fn start(&mut self, script: &str, timeout: Duration) -> Result<JobId, CoreError> {
        let permit = self.approve(script, timeout)?;
        self.supervisor.start(&mut self.actor, permit)
    }
    async fn output(&self, id: &JobId, stream: OutputStream) -> Result<(Vec<u8>, bool), CoreError> {
        let mut cursor = ByteOffset::ZERO;
        let mut bytes = Vec::new();
        let mut truncated = false;
        loop {
            let page = self.supervisor.read(&self.run, id, stream, cursor).await?;
            bytes.extend(page.bytes);
            truncated |= page.truncated;
            if page.next_cursor == cursor {
                break;
            }
            cursor = page.next_cursor;
        }
        Ok((bytes, truncated))
    }
    async fn ready(&self, id: &JobId) -> Result<Vec<u8>, CoreError> {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let page = self
                    .supervisor
                    .read(&self.run, id, OutputStream::Stdout, ByteOffset::ZERO)
                    .await?;
                if page.bytes.contains(&b'\n') {
                    return Ok(page.bytes);
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .map_err(|_| CoreError::Deadline)?
    }
}
fn name(value: &str) -> Result<ToolName, CoreError> {
    value.to_owned().try_into()
}
fn settings(root: &Path, mode: Mode, timeout: Duration) -> Result<RunSettings, CoreError> {
    RunSettings::new(
        mode,
        Workspace::try_from(root.to_path_buf())?,
        ToolCallLimit::default(),
        timeout,
        ConfigRevision::try_from(3)?,
        PolicyRevision::try_from(5)?,
    )
}
fn executable(name: &str) -> Result<PathBuf, CoreError> {
    let paths = std::env::var_os("PATH").ok_or(CoreError::Unavailable)?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
        .ok_or(CoreError::Unavailable)
}
fn command(root: &Path, script: &str, timeout: Duration) -> Result<CommandSpec, CoreError> {
    CommandSpec::try_from(CommandInput {
        program: executable("sh")?,
        arguments: vec!["-c".into(), script.into()],
        working_directory: root.to_path_buf(),
        timeout: Some(timeout),
        environment: CommandEnvironment::default(),
    })
}

#[test]
fn validated_values_reject_invalid_input_and_overflow() -> TestResult {
    assert!(LineNumber::try_from(0_usize).is_err());
    assert!(serde_json::from_str::<LineNumber>("0").is_err());
    assert!(serde_json::from_str::<ByteLimit>("0").is_err());
    assert!(ToolCallLimit::try_from(0).is_err());
    assert!(ToolName::try_from("../bash".to_owned()).is_err());
    assert!(RequestScope::try_from(String::new()).is_err());
    assert!(ApplicationId::try_from(SessionId::new().as_str().to_owned()).is_err());
    assert!(BoundedFloat::<0, 2>::try_from(f64::NAN).is_err());
    assert!(BoundedFloat::<0, 2>::try_from(f64::INFINITY).is_err());
    assert!(BoundedFloat::<0, 2>::try_from(2.01).is_err());
    assert_eq!(BoundedFloat::<0, 2>::try_from(0.7)?.as_f64(), 0.7);
    assert!(matches!(
        TokenCount::try_from(u64::MAX)?.next(),
        Err(CoreError::ArithmeticOverflow)
    ));
    assert!(matches!(
        MicroUsd::try_from(u64::MAX)?.checked_add(MicroUsd::try_from(1)?),
        Err(CoreError::ArithmeticOverflow)
    ));
    assert_ne!(ReasoningEffort::ProviderDefault, ReasoningEffort::Off);
    assert!(ExecutionTimeout::try_from(Some(Duration::ZERO)).is_err());
    assert!(ExecutionTimeout::try_from(Some(Duration::MAX)).is_err());
    assert!(ExecutionTimeout::try_from(None)?.duration().is_none());
    Ok(())
}

#[tokio::test]
async fn persistent_execution_has_no_synthetic_deadline_but_approval_is_bounded() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(2))?;
    f.actor.cancel(&f.run)?;
    f.actor.finish(&f.run)?;
    f.run = f.actor.admit(
        &f.session,
        RunSettings::persistent(
            Mode::Agent,
            Workspace::try_from(f.root.clone())?,
            ToolCallLimit::default(),
            ConfigRevision::ZERO,
            PolicyRevision::ZERO,
        ),
    )?;
    assert!(
        tokio::time::timeout(Duration::from_millis(20), f.run.deadline().elapsed())
            .await
            .is_err()
    );
    let spec = CommandSpec::try_from(CommandInput {
        program: executable("sh")?,
        arguments: vec![
            "-c".into(),
            "printf 'ready\\n'; read value; printf '%s' \"$value\"".into(),
        ],
        working_directory: f.root.clone(),
        timeout: None,
        environment: CommandEnvironment::default(),
    })?;
    let request = f.request_spec(spec)?;
    assert!(
        request
            .deadline()
            .saturating_duration_since(tokio::time::Instant::now())
            <= Duration::from_secs(300)
    );
    let grant = f
        .gate
        .decide(&mut f.actor, &f.run, &request, UserDecision::Approved)?;
    let job = f.supervisor.start(&mut f.actor, grant)?;
    f.ready(&job).await?;
    f.supervisor
        .write(&f.run, &job, InputChunk::try_from(b"accepted\n".to_vec())?)
        .await?;
    let result = f
        .supervisor
        .wait(&f.run, &job)
        .await?
        .deliver(&mut f.actor)?;
    assert_eq!(result.outcome, ToolOutcome::Ok);
    assert_eq!(
        f.output(&job, OutputStream::Stdout).await?.0,
        b"ready\naccepted"
    );
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn rolling_tail_keeps_recent_output_and_reports_the_skipped_byte_interval() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(5))?;
    let block = "x".repeat(1024);
    let script = format!(
        "i=0; while [ \"$i\" -lt 2048 ]; do printf '%s' '{block}'; i=$((i+1)); done; printf final-marker"
    );
    let spec =
        command(&f.root, &script, Duration::from_secs(4))?.with_retention(OutputRetention::Tail);
    let request = f.request_spec(spec)?;
    let grant = f
        .gate
        .decide(&mut f.actor, &f.run, &request, UserDecision::Approved)?;
    let job = f.supervisor.start(&mut f.actor, grant)?;
    let result = f
        .supervisor
        .wait(&f.run, &job)
        .await?
        .deliver(&mut f.actor)?;
    assert_eq!(result.outcome, ToolOutcome::Ok);
    let first = f
        .supervisor
        .read(&f.run, &job, OutputStream::Stdout, ByteOffset::ZERO)
        .await?;
    assert!(first.start_cursor > ByteOffset::ZERO);
    let (output, truncated) = f.output(&job, OutputStream::Stdout).await?;
    assert!(truncated);
    assert_eq!(output.len(), limits::PROCESS_OUTPUT_BYTES);
    assert!(output.ends_with(b"final-marker"));
    f.actor.finish(&f.run)?;
    Ok(())
}

#[test]
fn changing_retention_requires_a_different_exact_action_approval() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(5))?;
    let prefix = f.request("printf fixture", Duration::from_secs(2))?;
    let tail = f.request_spec(
        command(&f.root, "printf fixture", Duration::from_secs(2))?
            .with_retention(OutputRetention::Tail),
    )?;
    assert_ne!(prefix.digest(), tail.digest());
    for request in [prefix, tail] {
        assert!(matches!(
            f.gate
                .decide(&mut f.actor, &f.run, &request, UserDecision::Rejected),
            Err(CoreError::Rejected)
        ));
    }
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn completing_a_service_job_cannot_release_an_active_agent_turn() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(5))?;
    let job_run = f.actor.admit_job(
        &f.session,
        settings(&f.root, Mode::Agent, Duration::from_secs(2))?,
    )?;
    let request = f.gate.prepare(
        &mut f.actor,
        &job_run,
        &f.registry,
        &name("bash")?,
        ToolCallId::new(),
        command(&f.root, "printf service", Duration::from_secs(1))?,
    )?;
    let grant = f
        .gate
        .decide(&mut f.actor, &job_run, &request, UserDecision::Approved)?;
    let job = f.supervisor.start(&mut f.actor, grant)?;
    f.supervisor
        .wait(&job_run, &job)
        .await?
        .deliver(&mut f.actor)?;
    f.actor.finish(&job_run)?;
    f.actor.validate(&f.run)?;
    assert!(matches!(
        f.actor.admit(
            &f.session,
            settings(&f.root, Mode::Agent, Duration::from_secs(1))?
        ),
        Err(CoreError::Busy)
    ));
    f.actor.cancel(&f.run)?;
    f.actor.finish(&f.run)?;
    Ok(())
}

#[test]
fn mode_alias_owner_and_replay_gates_are_fail_closed() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let request = f.request("printf 'must not run' > denied", Duration::from_secs(2))?;
    assert_eq!(request.tool_name().as_str(), "bash");
    assert!(!f.run.drained());
    let mut foreign = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    assert!(matches!(
        f.gate
            .decide(&mut foreign.actor, &f.run, &request, UserDecision::Approved),
        Err(CoreError::StaleOwner)
    ));
    assert!(matches!(
        f.gate.dismiss_run(&mut foreign.actor, &f.run),
        Err(CoreError::StaleOwner)
    ));
    assert_eq!(f.gate.pending_count(), 1);
    assert!(matches!(
        f.gate
            .decide(&mut f.actor, &f.run, &request, UserDecision::Rejected),
        Err(CoreError::Rejected)
    ));
    assert!(matches!(
        f.gate
            .decide(&mut f.actor, &f.run, &request, UserDecision::Approved),
        Err(CoreError::ApprovalUnavailable)
    ));
    assert!(!f.root.join("denied").exists());
    assert!(f.run.drained());
    let summary = f.actor.finish(&f.run)?;
    assert_eq!(summary.tool_results.len(), 1);
    assert_eq!(
        summary.tool_results.first().map(|r| r.outcome),
        Some(ToolOutcome::Rejected)
    );
    let mut read_only = Fixture::new(Mode::Ask, Duration::from_secs(10))?;
    assert!(matches!(
        read_only.request("printf unsafe", Duration::from_secs(1)),
        Err(CoreError::Rejected)
    ));
    assert_eq!(read_only.gate.pending_count(), 0);
    assert!(
        read_only
            .actor
            .finish(&read_only.run)?
            .tool_results
            .is_empty()
    );
    // Aliases never overwrite a canonical definition or silently retarget it.
    f.registry.register_process(name("other")?, vec![])?;
    assert!(
        f.registry
            .register_process(name("third")?, vec![name("other")?])
            .is_err()
    );
    assert!(f.registry.resolve(&name("third")?).is_err());
    assert_eq!(
        f.registry.resolve(&name("terminal")?)?.safety(),
        ToolSafetyLevel::ExecutesArbitraryCode
    );
    Ok(())
}

#[test]
fn cancellation_repairs_pending_calls_in_ingress_order_before_release() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let first = f.request("printf first", Duration::from_secs(2))?;
    let second = f.request("printf second", Duration::from_secs(2))?;
    assert!(matches!(
        f.actor.admit(
            &f.session,
            settings(&f.root, Mode::Agent, Duration::from_secs(10))?
        ),
        Err(CoreError::Busy)
    ));
    f.actor.cancel(&f.run)?;
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::Busy)));
    assert!(matches!(
        f.gate
            .decide(&mut f.actor, &f.run, &first, UserDecision::Approved),
        Err(CoreError::Cancelled)
    ));
    f.gate.dismiss_run(&mut f.actor, &f.run)?;
    let summary = f.actor.finish(&f.run)?;
    assert_eq!(summary.tool_results.len(), 2);
    assert!(
        summary
            .tool_results
            .iter()
            .all(|r| r.outcome == ToolOutcome::Cancelled && r.is_error)
    );
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::StaleOwner)));
    let replacement = f.actor.admit(
        &f.session,
        settings(&f.root, Mode::Agent, Duration::from_secs(10))?,
    )?;
    assert!(replacement.scope().generation() > f.run.scope().generation());
    assert_ne!(first.id(), second.id());
    assert!(matches!(f.actor.cancel(&f.run), Err(CoreError::StaleOwner)));
    Ok(())
}

#[test]
fn action_binding_covers_argv_environment_and_runtime_revision() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let first = f.request("printf same", Duration::from_secs(1))?;
    let second = f.request("printf different", Duration::from_secs(1))?;
    assert_ne!(first.digest(), second.digest());
    let mut environment = BTreeMap::new();
    environment.insert(OsString::from("FIXTURE"), OsString::from("value"));
    let command = CommandSpec::try_from(CommandInput {
        program: executable("sh")?,
        arguments: vec!["-c".into(), "printf same".into()],
        working_directory: f.root.clone(),
        timeout: Some(Duration::from_secs(1)),
        environment: environment.try_into()?,
    })?;
    let third = f.gate.prepare(
        &mut f.actor,
        &f.run,
        &f.registry,
        &name("bash")?,
        ToolCallId::new(),
        command,
    )?;
    assert_ne!(first.digest(), third.digest());
    assert_eq!(third.environment().entries().count(), 1);
    let moved = f.root.with_file_name("moved-workspace");
    fs::rename(&f.root, &moved)?;
    fs::create_dir(&f.root)?;
    assert!(matches!(
        f.gate
            .decide(&mut f.actor, &f.run, &first, UserDecision::Approved),
        Err(CoreError::WorkspaceChanged)
    ));
    f.actor.cancel(&f.run)?;
    f.gate.dismiss_run(&mut f.actor, &f.run)?;
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn interactive_stdin_eof_output_exit_and_take_once_delivery() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let job = f.start(
        "IFS= read -r line; printf 'out:%s' \"$line\"; printf 'err' >&2; read rest; exit 7",
        Duration::from_secs(3),
    )?;
    f.supervisor
        .write(
            &f.run,
            &job,
            InputChunk::try_from("Türkçe🦀\n".as_bytes().to_vec())?,
        )
        .await?;
    f.supervisor.eof(&f.run, &job).await?;
    let completion = f.supervisor.wait(&f.run, &job).await?;
    assert_eq!(completion.result().outcome, ToolOutcome::Failed);
    assert_eq!(completion.result().exit_code, Some(7));
    assert!(completion.result().cleanup_complete);
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::Busy)));
    assert!(matches!(
        f.supervisor.wait(&f.run, &job).await,
        Err(CoreError::AlreadyCompleted)
    ));
    assert_eq!(f.supervisor.status(&f.run, &job)?, JobStatus::Collected);
    assert_eq!(
        f.output(&job, OutputStream::Stdout).await?.0,
        "out:Türkçe🦀".as_bytes()
    );
    assert_eq!(f.output(&job, OutputStream::Stderr).await?.0, b"err");
    completion.deliver(&mut f.actor)?;
    f.supervisor.forget(&f.run, &job)?;
    assert!(f.supervisor.jobs(&f.run).is_empty());
    let summary = f.actor.finish(&f.run)?;
    assert_eq!(
        summary.tool_results.first().map(|r| r.outcome),
        Some(ToolOutcome::Failed)
    );
    Ok(())
}

#[tokio::test]
async fn child_and_term_ignoring_descendant_are_killed_and_reaped() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let sleep = executable("sleep")?;
    let script = format!(
        "trap '' TERM; '{}' 60 & printf '%s\\n' \"$!\"; wait",
        sleep.display()
    );
    let job = f.start(&script, Duration::from_secs(5))?;
    let output = f.ready(&job).await?;
    let pid = std::str::from_utf8(&output)?.trim().parse::<u32>()?;
    assert!(PathBuf::from(format!("/proc/{pid}")).exists());
    f.actor.cancel(&f.run)?;
    let completion = f.supervisor.wait(&f.run, &job).await?;
    assert_eq!(completion.result().outcome, ToolOutcome::Cancelled);
    assert!(completion.result().cleanup_complete);
    assert!(!PathBuf::from(format!("/proc/{pid}")).exists());
    completion.deliver(&mut f.actor)?;
    let summary = f.actor.finish(&f.run)?;
    assert_eq!(
        summary.tool_results.first().map(|r| r.outcome),
        Some(ToolOutcome::Cancelled)
    );
    Ok(())
}

#[tokio::test]
async fn early_leader_exit_does_not_leave_descendants_or_open_pipes() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let sleep = executable("sleep")?;
    let script = format!(
        "trap '' TERM; '{}' 60 & printf '%s\\n' \"$!\"; exit 0",
        sleep.display()
    );
    let job = f.start(&script, Duration::from_secs(3))?;
    let completion = f.supervisor.wait(&f.run, &job).await?;
    assert!(completion.result().cleanup_complete);
    assert_eq!(completion.result().exit_code, Some(0));
    let output = f.output(&job, OutputStream::Stdout).await?.0;
    let pid = std::str::from_utf8(&output)?.trim().parse::<u32>()?;
    assert!(!PathBuf::from(format!("/proc/{pid}")).exists());
    completion.deliver(&mut f.actor)?;
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn timeout_and_foreign_job_operations_keep_their_actual_scope() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let foreign = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let job = f.start(
        "trap '' TERM; printf 'ready\\n'; read ignored",
        Duration::from_millis(100),
    )?;
    f.ready(&job).await?;
    assert!(matches!(
        f.supervisor.cancel(&foreign.run, &job),
        Err(CoreError::StaleOwner)
    ));
    assert!(matches!(
        f.supervisor
            .read(&foreign.run, &job, OutputStream::Stdout, ByteOffset::ZERO)
            .await,
        Err(CoreError::StaleOwner)
    ));
    assert!(f.supervisor.jobs(&foreign.run).is_empty());
    let completion = f.supervisor.wait(&f.run, &job).await?;
    assert_eq!(completion.result().outcome, ToolOutcome::Timeout);
    assert!(completion.result().cleanup_complete);
    completion.deliver(&mut f.actor)?;
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn cancelling_wait_keeps_the_job_supervised_and_siblings_live() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let first = f.start("printf 'ready\\n'; read ignored", Duration::from_secs(4))?;
    let second = f.start("read ignored; printf done", Duration::from_secs(4))?;
    f.ready(&first).await?;
    assert!(
        tokio::time::timeout(Duration::from_millis(20), f.supervisor.wait(&f.run, &first))
            .await
            .is_err()
    );
    f.supervisor.cancel(&f.run, &first)?;
    let completion = f.supervisor.wait(&f.run, &first).await?;
    assert_eq!(completion.result().outcome, ToolOutcome::Cancelled);
    completion.deliver(&mut f.actor)?;
    f.supervisor
        .write(
            &f.run,
            &second,
            InputChunk::try_from(b"continue\n".to_vec())?,
        )
        .await?;
    f.supervisor.eof(&f.run, &second).await?;
    let completion = f.supervisor.wait(&f.run, &second).await?;
    assert_eq!(completion.result().outcome, ToolOutcome::Ok);
    completion.deliver(&mut f.actor)?;
    assert_eq!(f.output(&second, OutputStream::Stdout).await?.0, b"done");
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn run_concurrency_is_bounded_and_claim_is_retained_during_drain() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let mut jobs = Vec::new();
    for _ in 0..limits::RUN_PROCESSES {
        jobs.push(f.start("read ignored", Duration::from_secs(4))?);
    }
    let fifth = f.approve("printf denied", Duration::from_secs(2))?;
    assert!(matches!(
        f.supervisor.start(&mut f.actor, fifth),
        Err(CoreError::Limit)
    ));
    f.actor.cancel(&f.run)?;
    assert!(matches!(f.actor.finish(&f.run), Err(CoreError::Busy)));
    for job in jobs {
        f.supervisor
            .wait(&f.run, &job)
            .await?
            .deliver(&mut f.actor)?;
    }
    let summary = f.actor.finish(&f.run)?;
    assert_eq!(summary.tool_results.len(), limits::RUN_PROCESSES + 1);
    assert_eq!(
        summary.tool_results.last().map(|r| r.outcome),
        Some(ToolOutcome::Failed)
    );
    Ok(())
}

#[tokio::test]
async fn output_caps_keep_draining_and_share_a_single_run_byte_budget() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(20))?;
    let block = "x".repeat(1024);
    let script = format!(
        "i=0; while [ \"$i\" -lt 2048 ]; do printf '%s' '{block}'; printf '%s' '{block}' >&2; i=$((i+1)); done"
    );
    let mut retained = 0;
    for _ in 0..5 {
        let job = f.start(&script, Duration::from_secs(4))?;
        let completion = f.supervisor.wait(&f.run, &job).await?;
        assert_eq!(completion.result().outcome, ToolOutcome::Ok);
        assert!(completion.result().cleanup_complete);
        for stream in [OutputStream::Stdout, OutputStream::Stderr] {
            let (bytes, truncated) = f.output(&job, stream).await?;
            assert!(truncated);
            assert!(bytes.len() <= limits::PROCESS_OUTPUT_BYTES);
            retained += bytes.len();
        }
        completion.deliver(&mut f.actor)?;
    }
    assert_eq!(retained, limits::RUN_OUTPUT_BYTES);
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn delayed_approval_and_delayed_execution_cannot_revive_an_expired_run() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_millis(120))?;
    let request = f.request("printf unsafe", Duration::from_secs(1))?;
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(matches!(
        f.gate
            .decide(&mut f.actor, &f.run, &request, UserDecision::Approved),
        Err(CoreError::Deadline)
    ));
    f.gate.dismiss_run(&mut f.actor, &f.run)?;
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Timeout)
    );
    let mut f = Fixture::new(Mode::Agent, Duration::from_millis(120))?;
    let permit = f.approve("printf unsafe", Duration::from_secs(1))?;
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(matches!(
        f.supervisor.start(&mut f.actor, permit),
        Err(CoreError::Deadline)
    ));
    assert!(f.supervisor.jobs(&f.run).is_empty());
    f.actor.finish(&f.run)?;
    Ok(())
}

#[tokio::test]
async fn executable_replacement_after_approval_is_rejected_before_spawn() -> TestResult {
    use std::os::unix::fs::PermissionsExt;
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let executable = f.root.join("executable");
    fs::write(&executable, b"#!/bin/sh\nprintf original")?;
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700))?;
    let spec = CommandSpec::try_from(CommandInput {
        program: executable.clone(),
        arguments: vec![],
        working_directory: f.root.clone(),
        timeout: Some(Duration::from_secs(2)),
        environment: CommandEnvironment::default(),
    })?;
    let request = f.gate.prepare(
        &mut f.actor,
        &f.run,
        &f.registry,
        &name("bash")?,
        ToolCallId::new(),
        spec,
    )?;
    let grant = f
        .gate
        .decide(&mut f.actor, &f.run, &request, UserDecision::Approved)?;
    fs::write(&executable, b"#!/bin/sh\nprintf changed-and-longer")?;
    assert!(matches!(
        f.supervisor.start(&mut f.actor, grant),
        Err(CoreError::WorkspaceChanged)
    ));
    assert!(f.supervisor.jobs(&f.run).is_empty());
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Rejected)
    );
    Ok(())
}

#[tokio::test]
async fn dropping_supervisor_cancels_children_and_preserves_unknown_effect_evidence() -> TestResult
{
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let job = f.start(
        "trap '' TERM; printf '%s\\n' \"$$\"; read ignored",
        Duration::from_secs(4),
    )?;
    let bytes = f.ready(&job).await?;
    let pid = std::str::from_utf8(&bytes)?.trim().parse::<u32>()?;
    let replacement = ProcessSupervisor::new(CleanupPolicy::default())?;
    drop(std::mem::replace(&mut f.supervisor, replacement));
    f.actor.cancel(&f.run)?;
    tokio::time::timeout(Duration::from_secs(3), async {
        while !f.run.drained() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await?;
    assert!(!PathBuf::from(format!("/proc/{pid}")).exists());
    let result = f.actor.finish(&f.run)?;
    assert_eq!(
        result.tool_results.first().map(|r| r.outcome),
        Some(ToolOutcome::OutcomeUnknown)
    );
    Ok(())
}

#[test]
fn tool_budget_is_not_a_token_or_process_slot_limit() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    for _ in 0..limits::TOOL_CALLS {
        f.request("printf unexecuted", Duration::from_secs(1))?;
    }
    assert!(
        matches!(f.request("printf over-budget",Duration::from_secs(1)),Err(CoreError::BudgetExceeded {spent,..})
        if spent.as_u64()==limits::TOOL_CALLS)
    );
    assert_eq!(u64::try_from(f.gate.pending_count())?, limits::TOOL_CALLS);
    f.actor.cancel(&f.run)?;
    f.gate.expire(&mut f.actor, &f.run)?;
    assert_eq!(f.gate.pending_count(), 0);
    assert_eq!(
        u64::try_from(f.actor.finish(&f.run)?.tool_results.len())?,
        limits::TOOL_CALLS
    );
    Ok(())
}

#[test]
fn attempting_spawn_without_a_runtime_is_a_typed_failure_not_a_panic() -> TestResult {
    let mut f = Fixture::new(Mode::Agent, Duration::from_secs(10))?;
    let grant = f.approve("printf unreachable", Duration::from_secs(1))?;
    assert!(matches!(
        f.supervisor.start(&mut f.actor, grant),
        Err(CoreError::Unavailable)
    ));
    assert!(f.run.drained());
    assert_eq!(
        f.actor
            .finish(&f.run)?
            .tool_results
            .first()
            .map(|r| r.outcome),
        Some(ToolOutcome::Failed)
    );
    Ok(())
}
