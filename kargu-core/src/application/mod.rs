//! Single-writer admission, claims, tool ledger and revoke/drain/release lifecycle.

pub mod budget;
pub mod host;
mod jobs;

use crate::{constants::limits, domain::*, error::CoreError, security::Workspace};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

/// Existing Kargu modes; execution is checked again after approval.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    /// Read-only question mode.
    Ask,
    /// Read-only planning mode.
    Plan,
    /// Debugger-aware mode.
    Debug,
    /// General code and shell execution mode.
    Agent,
}

/// Immutable captured settings. Changing selection cannot retarget existing work.
#[derive(Clone)]
pub struct RunSettings {
    pub(crate) mode: Mode,
    pub(crate) workspace: Workspace,
    pub(crate) tool_limit: ToolCallLimit,
    timeout: ExecutionTimeout,
    config_revision: ConfigRevision,
    policy_revision: PolicyRevision,
}
impl RunSettings {
    /// Capture validated settings; zero or overflowing deadlines are rejected.
    pub fn new(
        mode: Mode,
        workspace: Workspace,
        tool_limit: ToolCallLimit,
        timeout: Duration,
        config_revision: ConfigRevision,
        policy_revision: PolicyRevision,
    ) -> Result<Self, CoreError> {
        let timeout = ExecutionTimeout::try_from(timeout)?;
        Ok(Self {
            mode,
            workspace,
            tool_limit,
            timeout,
            config_revision,
            policy_revision,
        })
    }
    /// Explicit persistent service execution; approval and cleanup remain bounded.
    pub fn persistent(
        mode: Mode,
        workspace: Workspace,
        tool_limit: ToolCallLimit,
        config_revision: ConfigRevision,
        policy_revision: PolicyRevision,
    ) -> Self {
        Self {
            mode,
            workspace,
            tool_limit,
            timeout: ExecutionTimeout::UNLIMITED,
            config_revision,
            policy_revision,
        }
    }
}

pub(crate) struct PreparedEditorSettings(RunSettings);
impl RunSettings {
    pub(crate) fn prepare_editor(self) -> Result<PreparedEditorSettings, CoreError> {
        self.workspace.revalidate()?;
        Ok(PreparedEditorSettings(self))
    }
}
impl ApplicationActor {
    pub(crate) fn admit_editor(
        &mut self,
        session: &SessionId,
        settings: PreparedEditorSettings,
    ) -> Result<RunHandle, CoreError> {
        self.check_admission()?;
        if self.editor_runs.len() >= limits::EDIT_PREPARATIONS {
            return Err(CoreError::Limit);
        }
        let run = self.capture_owned_run(session, settings.0, RunPurpose::EditorEdit)?;
        let handle = run.handle.clone();
        self.editor_runs.insert(handle.scope.run_id().clone(), run);
        Ok(handle)
    }
}

/// Whether execution occupies the foreground turn or a separate owned job lifetime.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunPurpose {
    /// The application's one foreground agent/standalone-command claim.
    AgentTurn,
    /// An explicitly owned process service job, not another concurrent agent turn.
    ProcessJob,
    /// A prepared editor action, including asynchronous review and actual settlement.
    EditorEdit,
}

/// Identity and revision evidence, serialized without granting execution rights.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunScope {
    purpose: RunPurpose,
    application_id: ApplicationId,
    session_id: SessionId,
    run_id: RunId,
    claim_id: ClaimId,
    generation: Generation,
    config_revision: ConfigRevision,
    policy_revision: PolicyRevision,
}
impl RunScope {
    /// Execution lifetime category, included in exact-action approval identity.
    pub fn purpose(&self) -> RunPurpose {
        self.purpose
    }
    /// Captured application.
    pub fn application_id(&self) -> &ApplicationId {
        &self.application_id
    }
    /// Captured conversation.
    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }
    /// Configuration revision frozen at actual native admission.
    pub fn config_revision(&self) -> ConfigRevision {
        self.config_revision
    }
    /// Policy revision frozen at actual native admission.
    pub fn policy_revision(&self) -> PolicyRevision {
        self.policy_revision
    }
    /// Current run identity, independent of the admission claim.
    pub fn run_id(&self) -> &RunId {
        &self.run_id
    }
    /// Monotonic generation.
    pub fn generation(&self) -> Generation {
        self.generation
    }
}

struct Resources {
    cancellation: CancellationToken,
    pending: AtomicUsize,
    process_slots: Arc<Semaphore>,
    output: AtomicUsize,
}

/// Unforgeable in-process run handle. DTOs cannot construct or deserialize one.
#[derive(Clone)]
pub struct RunHandle {
    scope: RunScope,
    settings: RunSettings,
    deadline: Deadline,
    resources: Arc<Resources>,
}
impl RunHandle {
    /// Borrow immutable captured scope.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Captured deadline shared by tools and approval waits.
    pub fn deadline(&self) -> Deadline {
        self.deadline
    }
    /// Reject revoked or expired execution/publication rights.
    pub fn check_live(&self) -> Result<(), CoreError> {
        if self.resources.cancellation.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if self.deadline.expired() {
            return Err(CoreError::Deadline);
        }
        Ok(())
    }
    /// Whether all acquired resources and undelivered completions have drained.
    pub fn drained(&self) -> bool {
        self.resources.pending.load(Ordering::Acquire) == 0
    }
    pub(crate) fn same_owner(&self, other: &Self) -> bool {
        self.scope == other.scope && Arc::ptr_eq(&self.resources, &other.resources)
    }
    pub(crate) fn settings(&self) -> &RunSettings {
        &self.settings
    }
    pub(crate) fn cancel_token(&self) -> CancellationToken {
        self.resources.cancellation.child_token()
    }
    pub(crate) fn process_slots(&self) -> Arc<Semaphore> {
        self.resources.process_slots.clone()
    }
    pub(crate) fn reserve_output(&self, available: ByteLimit) -> usize {
        let mut taken = 0;
        let _ = self
            .resources
            .output
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                taken = available
                    .as_usize()
                    .min(limits::RUN_OUTPUT_BYTES.saturating_sub(used));
                used.checked_add(taken)
            });
        taken
    }
    pub(crate) fn lease(&self) -> Result<RunLease, CoreError> {
        self.check_live()?;
        self.resources
            .pending
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
            .map_err(|_| CoreError::ArithmeticOverflow)?;
        let lease = RunLease {
            resources: self.resources.clone(),
        };
        self.check_live()?;
        Ok(lease)
    }
}

pub(crate) struct RunLease {
    resources: Arc<Resources>,
}
impl Drop for RunLease {
    fn drop(&mut self) {
        self.resources.pending.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Canonical terminal classification. Human text never controls retry or success.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolOutcome {
    /// Executor returned exit success.
    Ok,
    /// Executor failed or returned nonzero exit.
    Failed,
    /// User/owner cancelled.
    Cancelled,
    /// Operation deadline elapsed.
    Timeout,
    /// Policy or user denied execution.
    Rejected,
    /// Side effects could not be established after interruption.
    OutcomeUnknown,
}
impl ToolOutcome {
    /// Sanitized fallback text for synthetic results; actual output is separately archived.
    pub const fn summary(self) -> &'static str {
        match self {
            Self::Ok => "Operation completed",
            Self::Failed => "ERROR: operation failed",
            Self::Cancelled => "ERROR: [ABORTED] operation cancelled by user or owner",
            Self::Timeout => "ERROR: [TIMEOUT] operation deadline exceeded",
            Self::Rejected => "ERROR: operation rejected by policy or user",
            Self::OutcomeUnknown => {
                "ERROR: [INTERRUPTED] effects are unknown; do not replay automatically"
            }
        }
    }
}

struct Call {
    name: ToolName,
    started: bool,
    outcome: Option<ToolOutcome>,
}
struct ActiveRun {
    handle: RunHandle,
    calls: HashMap<ToolCallId, Call>,
    call_order: Vec<ToolCallId>,
    spent: StepCount,
    cleanup_failed: bool,
}

/// Protocol repair evidence for one committed tool call.
#[derive(Debug, Serialize)]
pub struct ToolResult {
    /// Original tool call identity.
    pub tool_call_id: ToolCallId,
    /// Canonical registry name.
    pub tool_name: ToolName,
    /// Typed terminal status.
    pub outcome: ToolOutcome,
    /// Provider adapters use this when constructing error tool results.
    pub is_error: bool,
    /// Safe cancellation/error notice, including synthesized interrupted calls.
    pub message: &'static str,
}

/// Released run, with exactly one result for every registered call.
#[derive(Debug, Serialize)]
pub struct RunCompletion {
    /// Released run scope.
    pub scope: RunScope,
    /// Idempotently repaired call results; wire-family serialization is later work.
    pub tool_results: Vec<ToolResult>,
}

/// Domain actor: all state changes require exclusive access, never an I/O await.
pub struct ApplicationActor {
    id: ApplicationId,
    sessions: HashSet<SessionId>,
    generation: Generation,
    active: Option<ActiveRun>,
    job_runs: HashMap<RunId, ActiveRun>,
    editor_runs: HashMap<RunId, ActiveRun>,
    pub(crate) models: crate::models::service::ModelService,
    pub(crate) edits: crate::edit::prepare::EditPreparations,
    pub(crate) configuration: crate::configuration::policy::ConfigurationService,
}
impl ApplicationActor {
    /// Create an empty application; composition owns this handle.
    pub fn new(id: ApplicationId) -> Self {
        Self {
            id,
            sessions: HashSet::new(),
            generation: Generation::ZERO,
            active: None,
            job_runs: HashMap::new(),
            editor_runs: HashMap::new(),
            models: crate::models::service::ModelService::default(),
            edits: crate::edit::prepare::EditPreparations::default(),
            configuration: crate::configuration::policy::ConfigurationService::default(),
        }
    }
    /// Register a new conversation without admitting a run.
    pub fn create_session(&mut self) -> SessionId {
        let id = SessionId::new();
        self.sessions.insert(id.clone());
        id
    }
    /// Registered conversation count for host admission limits.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }
    /// Whether the application owns this conversation.
    pub fn owns_session(&self, session: &SessionId) -> bool {
        self.sessions.contains(session)
    }
    /// Close only an idle conversation.
    pub fn close_session(&mut self, session: &SessionId) -> Result<(), CoreError> {
        if self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
            .any(|run| &run.handle.scope.session_id == session)
        {
            return Err(CoreError::Busy);
        }
        if self.sessions.remove(session) {
            self.models.close_session(session);
            self.configuration.close_session(session);
            self.edits.close_session(session);
            Ok(())
        } else {
            Err(CoreError::StaleOwner)
        }
    }
    /// Revoke a closing IPC owner immediately, retaining its run until drain.
    pub(crate) fn revoke_session(&mut self, session: &SessionId) -> Result<(), CoreError> {
        if !self.sessions.remove(session) {
            return Err(CoreError::StaleOwner);
        }
        self.models.close_session(session);
        self.configuration.close_session(session);
        self.edits.close_session(session);
        for run in self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
        {
            if run.handle.scope.session_id() == session {
                run.handle.resources.cancellation.cancel();
            }
        }
        Ok(())
    }
    /// Revoke application admission/publication while retaining live run ledgers.
    pub(crate) fn revoke_all(&mut self) {
        self.models.revoke();
        self.configuration.revoke();
        self.edits.revoke();
        self.sessions.clear();
        for run in self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
        {
            run.handle.resources.cancellation.cancel();
        }
    }
    pub(crate) fn drained(&self) -> bool {
        self.active.is_none() && self.job_runs.is_empty() && self.editor_runs.is_empty()
    }
    /// Claim before any async preparation, policy UI, spawn or view effect.
    pub fn admit(
        &mut self,
        session: &SessionId,
        settings: RunSettings,
    ) -> Result<RunHandle, CoreError> {
        if self.active.is_some() {
            return Err(CoreError::Busy);
        }
        self.check_admission()?;
        let run = self.capture_run(session, settings, RunPurpose::AgentTurn)?;
        let handle = run.handle.clone();
        self.active = Some(run);
        Ok(handle)
    }
    fn capture_run(
        &mut self,
        session: &SessionId,
        settings: RunSettings,
        purpose: RunPurpose,
    ) -> Result<ActiveRun, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        settings.workspace.revalidate()?;
        self.capture_owned_run(session, settings, purpose)
    }
    fn capture_owned_run(
        &mut self,
        session: &SessionId,
        settings: RunSettings,
        purpose: RunPurpose,
    ) -> Result<ActiveRun, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let generation = self.generation.next()?;
        let deadline = settings.timeout.start()?;
        let handle = RunHandle {
            scope: RunScope {
                purpose,
                application_id: self.id.clone(),
                session_id: session.clone(),
                run_id: RunId::new(),
                claim_id: ClaimId::new(),
                generation,
                config_revision: settings.config_revision,
                policy_revision: settings.policy_revision,
            },
            settings,
            deadline,
            resources: Arc::new(Resources {
                cancellation: CancellationToken::new(),
                pending: AtomicUsize::new(0),
                process_slots: Arc::new(Semaphore::new(limits::RUN_PROCESSES)),
                output: AtomicUsize::new(0),
            }),
        };
        self.generation = generation;
        Ok(ActiveRun {
            handle,
            calls: HashMap::new(),
            call_order: Vec::new(),
            spent: StepCount::ZERO,
            cleanup_failed: false,
        })
    }
    /// Validate current ownership without permitting a different actor to release it.
    pub fn validate(&self, handle: &RunHandle) -> Result<(), CoreError> {
        self.owned(handle)?;
        handle.check_live()
    }
    pub(crate) fn validate_owner(&self, handle: &RunHandle) -> Result<(), CoreError> {
        self.owned(handle).map(|_| ())
    }
    fn owned(&self, handle: &RunHandle) -> Result<&ActiveRun, CoreError> {
        self.active
            .as_ref()
            .filter(|r| r.handle.same_owner(handle))
            .or_else(|| {
                self.job_runs
                    .get(handle.scope.run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .or_else(|| {
                self.editor_runs
                    .get(handle.scope.run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .ok_or(CoreError::StaleOwner)
    }
    fn owned_mut(&mut self, handle: &RunHandle) -> Result<&mut ActiveRun, CoreError> {
        self.active
            .as_mut()
            .filter(|r| r.handle.same_owner(handle))
            .or_else(|| {
                self.job_runs
                    .get_mut(handle.scope.run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .or_else(|| {
                self.editor_runs
                    .get_mut(handle.scope.run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .ok_or(CoreError::StaleOwner)
    }
    pub(crate) fn register_call(
        &mut self,
        handle: &RunHandle,
        id: ToolCallId,
        name: ToolName,
    ) -> Result<(), CoreError> {
        self.validate(handle)?;
        let run = self.owned_mut(handle)?;
        if run.calls.contains_key(&id) {
            return Err(CoreError::AlreadyCompleted);
        }
        if !handle.settings.tool_limit.permits(run.spent) {
            return Err(CoreError::BudgetExceeded {
                limit: handle.settings.tool_limit,
                spent: run.spent,
            });
        }
        run.spent = run.spent.next()?;
        run.call_order.push(id.clone());
        run.calls.insert(
            id,
            Call {
                name,
                started: false,
                outcome: None,
            },
        );
        Ok(())
    }
    pub(crate) fn mark_started(
        &mut self,
        handle: &RunHandle,
        id: &ToolCallId,
    ) -> Result<(), CoreError> {
        self.validate(handle)?;
        let call = self
            .owned_mut(handle)?
            .calls
            .get_mut(id)
            .ok_or(CoreError::StaleOwner)?;
        if call.started || call.outcome.is_some() {
            return Err(CoreError::AlreadyCompleted);
        }
        call.started = true;
        Ok(())
    }
    /// Consume a terminal tool completion once; cancellation cannot overwrite a real result.
    pub fn complete_tool(
        &mut self,
        handle: &RunHandle,
        id: &ToolCallId,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        let call = self
            .owned_mut(handle)?
            .calls
            .get_mut(id)
            .ok_or(CoreError::StaleOwner)?;
        if call.outcome.is_some() {
            return Err(CoreError::AlreadyCompleted);
        }
        call.outcome = Some(outcome);
        Ok(())
    }
    pub(crate) fn quarantine(&mut self, handle: &RunHandle) -> Result<(), CoreError> {
        self.owned_mut(handle)?.cleanup_failed = true;
        handle.resources.cancellation.cancel();
        Ok(())
    }
    /// Revoke rights first. The claim remains owned until resources drain and repair finishes.
    pub fn cancel(&mut self, handle: &RunHandle) -> Result<(), CoreError> {
        self.owned(handle)?.handle.resources.cancellation.cancel();
        Ok(())
    }
    /// Drain-before-release and idempotent history repair of all open call identities.
    pub fn finish(&mut self, handle: &RunHandle) -> Result<RunCompletion, CoreError> {
        let run = self.owned(handle)?;
        if run.cleanup_failed {
            return Err(CoreError::CleanupFailed);
        }
        if !handle.drained() {
            return Err(CoreError::Busy);
        }
        let interrupted = handle.check_live().is_err();
        if !interrupted && run.calls.values().any(|call| call.outcome.is_none()) {
            return Err(CoreError::Busy);
        }
        let mut results = Vec::new();
        for id in &run.call_order {
            let call = run.calls.get(id).ok_or(CoreError::StaleOwner)?;
            let outcome = call.outcome.unwrap_or(if call.started {
                ToolOutcome::OutcomeUnknown
            } else if handle.deadline.expired() {
                ToolOutcome::Timeout
            } else {
                ToolOutcome::Cancelled
            });
            results.push(ToolResult {
                tool_call_id: id.clone(),
                tool_name: call.name.clone(),
                is_error: outcome != ToolOutcome::Ok,
                message: outcome.summary(),
                outcome,
            });
        }
        let completion = RunCompletion {
            scope: handle.scope.clone(),
            tool_results: results,
        };
        handle.resources.cancellation.cancel();
        match handle.scope.purpose() {
            RunPurpose::AgentTurn => self.active = None,
            RunPurpose::ProcessJob => {
                self.job_runs.remove(handle.scope.run_id());
            }
            RunPurpose::EditorEdit => {
                self.editor_runs.remove(handle.scope.run_id());
            }
        }
        Ok(completion)
    }
}
impl Drop for ApplicationActor {
    fn drop(&mut self) {
        for run in self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
        {
            run.handle.resources.cancellation.cancel();
        }
    }
}
