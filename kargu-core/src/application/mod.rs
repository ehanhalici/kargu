//! Single-writer admission, claims, tool ledger and revoke/drain/release lifecycle.

pub mod agent;
pub mod budget;
mod claim;
mod history;
mod steps;
pub use claim::{ClaimIntent, ClaimLease, PreparedRun, RequestedWorkspace, RunClaim};
pub mod host;
mod jobs;
pub mod mode;
pub mod plan;
pub mod restore;
pub mod selection;

use crate::{
    constants::limits,
    domain::*,
    error::CoreError,
    security::{ToolRegistry, Workspace},
};
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
    workspace: Workspace,
    tool_limit: ToolCallLimit,
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
    registry: Arc<ToolRegistry>,
}
impl RunHandle {
    /// Immutable application catalog captured at claim acquisition.
    pub fn tool_registry(&self) -> &ToolRegistry {
        &self.registry
    }
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
    /// Captured mode for this run.
    pub fn mode(&self) -> Mode {
        self.settings.mode
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
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
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

enum CallAdmission {
    Unclaimed,
    Claimed,
}
struct Call {
    name: ToolName,
    started: bool,
    outcome: Option<ToolOutcome>,
    admission: CallAdmission,
    safety: Option<ToolSafetyLevel>,
}
struct ActiveRun {
    handle: RunHandle,
    calls: HashMap<ToolCallId, Call>,
    call_order: Vec<ToolCallId>,
    spent: StepCount,
    cleanup_failed: bool,
    agent: Option<agent::AgentMachine>,
    steps: HashMap<ToolStepId, steps::ExecutionStep>,
}

/// Protocol repair evidence for one committed tool call.
#[derive(Debug, Serialize)]
pub struct ToolResult {
    /// Original tool call identity.
    pub tool_call_id: ToolCallId,
    /// Canonical registry name.
    tool_name: ToolName,
    /// Typed terminal status.
    pub outcome: ToolOutcome,
    /// Provider adapters use this when constructing error tool results.
    pub is_error: bool,
    /// Safe cancellation/error notice, including synthesized interrupted calls.
    message: &'static str,
}

/// Released run, with exactly one result for every registered call.
#[derive(Debug, Serialize)]
pub struct RunCompletion {
    /// Released run scope.
    scope: RunScope,
    /// Idempotently repaired call results; wire-family serialization is later work.
    tool_results: Vec<ToolResult>,
}

/// Domain actor: all state changes require exclusive access, never an I/O await.
pub struct ApplicationActor {
    id: ApplicationId,
    registry: Arc<ToolRegistry>,
    sessions: HashSet<SessionId>,
    histories: HashMap<SessionId, crate::history::History>,
    selections: HashMap<SessionId, selection::SessionSelection>,
    modes: HashMap<SessionId, mode::SessionMode>,
    plans: HashMap<SessionId, plan::SessionPlanStore>,
    session_events: HashMap<SessionId, SessionEventSequence>,
    session_roots: HashMap<SessionId, std::path::PathBuf>,
    session_accounting: HashMap<SessionId, restore::SessionAccounting>,
    history_imports: crate::history::HistoryImports,
    generation: Generation,
    active: Option<ActiveRun>,
    preparing: Option<claim::PendingClaim>,
    job_runs: HashMap<RunId, ActiveRun>,
    editor_runs: HashMap<RunId, ActiveRun>,
    models: crate::models::service::ModelService,
    pub(crate) edits: crate::edit::prepare::EditPreparations,
    configuration: crate::configuration::policy::ConfigurationService,
}
impl ApplicationActor {
    /// Create an empty application; composition owns this handle.
    pub fn new(id: ApplicationId) -> Self {
        Self {
            id,
            registry: Arc::new(ToolRegistry::default()),
            sessions: HashSet::new(),
            histories: HashMap::new(),
            selections: HashMap::new(),
            modes: HashMap::new(),
            plans: HashMap::new(),
            session_events: HashMap::new(),
            session_roots: HashMap::new(),
            session_accounting: HashMap::new(),
            history_imports: crate::history::HistoryImports::default(),
            generation: Generation::ZERO,
            active: None,
            preparing: None,
            job_runs: HashMap::new(),
            editor_runs: HashMap::new(),
            models: crate::models::service::ModelService::default(),
            edits: crate::edit::prepare::EditPreparations::default(),
            configuration: crate::configuration::policy::ConfigurationService::default(),
        }
    }
    /// Compose an application with its explicit trusted execution catalog.
    pub fn with_registry(id: ApplicationId, registry: ToolRegistry) -> Self {
        let mut actor = Self::new(id);
        actor.registry = Arc::new(registry);
        actor
    }
    /// Detached immutable catalog; siblings never share mutable registrations.
    pub fn tool_registry(&self) -> Arc<ToolRegistry> {
        self.registry.clone()
    }
    /// Register a new conversation without admitting a run.
    pub fn create_session(&mut self) -> SessionId {
        let id = SessionId::new();
        self.sessions.insert(id.clone());
        self.histories
            .insert(id.clone(), crate::history::History::default());
        self.selections
            .insert(id.clone(), selection::SessionSelection::default());
        self.modes.insert(id.clone(), mode::SessionMode::default());
        self.session_events
            .insert(id.clone(), SessionEventSequence::ZERO);
        self.session_roots.remove(&id);
        self.session_accounting
            .insert(id.clone(), restore::SessionAccounting::default());
        id
    }
    /// Registered conversation count for host admission limits.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }
    /// Advance native UI event ordering without allowing a view to mutate history.
    pub(crate) fn next_session_event(
        &mut self,
        session: &SessionId,
    ) -> Result<SessionEventSequence, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let sequence = self
            .session_events
            .get_mut(session)
            .ok_or(CoreError::StaleOwner)?;
        *sequence = sequence.next()?;
        Ok(*sequence)
    }
    /// Whether the application owns this conversation.
    pub fn owns_session(&self, session: &SessionId) -> bool {
        self.sessions.contains(session)
    }
    /// Detached committed provider/model/effort choice for one owned conversation.
    pub fn session_selection(
        &self,
        session: &SessionId,
    ) -> Result<&selection::SessionSelection, CoreError> {
        self.selections.get(session).ok_or(CoreError::StaleOwner)
    }
    /// Commit a complete selection from its observed revision.
    ///
    /// Admission or an active run locks every conversation's choice, matching
    /// the application-wide single active run.
    pub fn commit_session_selection(
        &mut self,
        session: &SessionId,
        expected: selection::SelectionRevision,
        desired: selection::Selection,
    ) -> Result<&selection::SessionSelection, CoreError> {
        let locked = self.active.is_some() || self.preparing.is_some();
        let store = self
            .selections
            .get_mut(session)
            .ok_or(CoreError::StaleOwner)?;
        store.commit(expected, desired, locked)?;
        Ok(store)
    }
    /// Detached committed mode and revision for one owned conversation.
    pub fn session_mode(&self, session: &SessionId) -> Result<&mode::SessionMode, CoreError> {
        self.modes.get(session).ok_or(CoreError::StaleOwner)
    }
    /// Commit a mode change from its observed expected revision.
    pub fn commit_session_mode(
        &mut self,
        session: &SessionId,
        expected: mode::ModeRevision,
        intent: mode::ModeIntent,
    ) -> Result<&mode::SessionMode, CoreError> {
        let locked = mode::ModeLock::new(self.active.is_some() || self.preparing.is_some());
        let store = self.modes.get_mut(session).ok_or(CoreError::StaleOwner)?;
        store.commit(expected, intent, locked)?;
        Ok(store)
    }
    /// Available tools for the specified mode.
    pub fn available_tools_for_mode(&self, mode: Mode) -> Vec<ToolName> {
        self.registry.available_tools_for_mode(mode)
    }
    /// Read one conversation's active plan record, if any.
    pub fn session_plan(&self, session: &SessionId) -> Option<&plan::PlanRecord> {
        self.plans
            .get(session)
            .and_then(|store| store.active_record())
    }
    /// Read one conversation's plan record by id, if any.
    pub fn session_plan_by_id(
        &self,
        session: &SessionId,
        plan_id: &PlanId,
    ) -> Option<&plan::PlanRecord> {
        self.plans
            .get(session)
            .and_then(|store| store.get_record(plan_id))
    }
    /// Create or replace an implementation plan for one owned conversation.
    pub fn create_session_plan(
        &mut self,
        session: &SessionId,
        text: plan::PlanText,
    ) -> Result<&plan::PlanRecord, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let store = self.plans.entry(session.clone()).or_default();
        store.create_or_replace(session.clone(), text)
    }
    /// Revise plan content and bump monotonic revision.
    pub fn revise_session_plan(
        &mut self,
        session: &SessionId,
        plan_id: &PlanId,
        intent: plan::PlanReviseIntent,
    ) -> Result<&plan::PlanRecord, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let store = self.plans.get_mut(session).ok_or(CoreError::StaleOwner)?;
        store.revise(plan_id, intent)
    }
    /// Claim a plan for execution (single-use accept).
    pub fn claim_session_plan(
        &mut self,
        session: &SessionId,
        plan_id: &PlanId,
        intent: plan::PlanClaimIntent,
    ) -> Result<&plan::PlanRecord, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        if self.active.is_some() || self.preparing.is_some() {
            return Err(CoreError::Busy);
        }
        let store = self.plans.get_mut(session).ok_or(CoreError::StaleOwner)?;
        store.claim(plan_id, intent)
    }
    /// Settle claimed plan dispatch.
    pub fn complete_session_plan(
        &mut self,
        session: &SessionId,
        plan_id: &PlanId,
        success: plan::PlanDispatchSuccess,
    ) -> Result<plan::PlanState, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let store = self.plans.get_mut(session).ok_or(CoreError::StaleOwner)?;
        store.complete_dispatch(plan_id, success)
    }
    /// Reject a pending plan.
    pub fn reject_session_plan(
        &mut self,
        session: &SessionId,
        plan_id: &PlanId,
        expected_revision: PlanRevision,
    ) -> Result<plan::PlanState, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        let store = self.plans.get_mut(session).ok_or(CoreError::StaleOwner)?;
        store.reject(plan_id, expected_revision)
    }
    pub(crate) fn session_projection(
        &self,
        session: &SessionId,
    ) -> Result<serde_json::Value, CoreError> {
        let history = self.session_history(session)?;
        let mode_store = self.modes.get(session).ok_or(CoreError::StaleOwner)?;
        let sequence = self
            .session_events
            .get(session)
            .ok_or(CoreError::StaleOwner)?;
        let preparing = self
            .preparing
            .as_ref()
            .filter(|pending| pending.claim().scope().session_id() == session);
        let active = self
            .active
            .as_ref()
            .filter(|active| active.handle.scope().session_id() == session);
        let (state, scope, phase) = if let Some(pending) = preparing {
            let state = if pending.claim().check_live().is_ok() {
                "preparing"
            } else {
                "draining"
            };
            (state, Some(pending.claim().scope()), None)
        } else if let Some(active) = active {
            let state = if active.handle.check_live().is_ok() {
                "running"
            } else {
                "draining"
            };
            let phase = active
                .agent
                .as_ref()
                .map(|_| self.agent_phase(&active.handle))
                .transpose()?;
            (state, Some(active.handle.scope()), phase)
        } else {
            ("idle", None, None)
        };
        let mut proj = serde_json::json!({
            "state": state,
            "active_run": scope,
            "phase": phase,
            "mode": mode_store.mode(),
            "mode_revision": mode_store.revision(),
            "generation": scope.map_or(self.generation, RunScope::generation),
            "sequence": sequence,
            "history_revision": history.revision()
        });
        if let Some(obj) = proj.as_object_mut() {
            if let Some(root) = self.session_root(session) {
                obj.insert("project_root".to_owned(), serde_json::json!(root));
            }
            if let Some(acc) = self.session_accounting(session) {
                obj.insert("accounting".to_owned(), serde_json::json!(acc));
            }
        }
        Ok(proj)
    }
    /// Close only an idle conversation.
    pub fn close_session(&mut self, session: &SessionId) -> Result<(), CoreError> {
        if self
            .preparing
            .as_ref()
            .is_some_and(|pending| pending.claim().scope().session_id() == session)
        {
            return Err(CoreError::Busy);
        }
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
            self.history_imports.revoke(Some(session));
            self.histories.remove(session);
            self.selections.remove(session);
            self.modes.remove(session);
            self.plans.remove(session);
            self.session_events.remove(session);
            self.session_roots.remove(session);
            self.session_accounting.remove(session);
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
        self.session_events.remove(session);
        self.selections.remove(session);
        self.modes.remove(session);
        self.plans.remove(session);
        self.session_roots.remove(session);
        self.session_accounting.remove(session);
        self.revoke_preparing(Some(session));
        self.history_imports.revoke(Some(session));
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
        self.prune_retired_histories();
        Ok(())
    }
    /// Revoke application admission/publication while retaining live run ledgers.
    pub(crate) fn revoke_all(&mut self) {
        self.revoke_preparing(None);
        self.history_imports.revoke(None);
        self.models.revoke();
        self.configuration.revoke();
        self.edits.revoke();
        self.sessions.clear();
        self.session_events.clear();
        self.session_roots.clear();
        self.session_accounting.clear();
        for run in self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
        {
            run.handle.resources.cancellation.cancel();
        }
        self.prune_retired_histories();
    }
    pub(crate) fn drained(&self) -> bool {
        self.active.is_none()
            && self.preparing.is_none()
            && self.job_runs.is_empty()
            && self.editor_runs.is_empty()
            && self.history_imports.drained()
    }
    /// Claim before any async preparation, policy UI, spawn or view effect.
    pub fn admit(
        &mut self,
        session: &SessionId,
        settings: RunSettings,
    ) -> Result<RunHandle, CoreError> {
        if self.active.is_some() || self.preparing.is_some() {
            return Err(CoreError::Busy);
        }
        if self.history_imports.owns_session(session) {
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
            registry: self.registry.clone(),
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
            steps: HashMap::new(),
            agent: None,
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
                admission: CallAdmission::Unclaimed,
                safety: None,
            },
        );
        Ok(())
    }
    /// Bind a committed model call to one gate without charging it a second time.
    pub(crate) fn reserve_call(
        &mut self,
        handle: &RunHandle,
        id: ToolCallId,
        name: ToolName,
        safety: ToolSafetyLevel,
    ) -> Result<(), CoreError> {
        self.validate(handle)?;
        if let Some(agent) = &self.owned(handle)?.agent {
            agent.check_dispatch(&id)?;
        }
        if !self.owned(handle)?.calls.contains_key(&id) {
            self.register_call(handle, id.clone(), name.clone())?;
        }
        let call = self
            .owned_mut(handle)?
            .calls
            .get_mut(&id)
            .ok_or(CoreError::StaleOwner)?;
        if call.name != name
            || call.started
            || call.outcome.is_some()
            || matches!(call.admission, CallAdmission::Claimed)
        {
            return Err(CoreError::AlreadyCompleted);
        }
        call.admission = CallAdmission::Claimed;
        call.safety = Some(safety);
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
        if call.started
            || call.outcome.is_some()
            || !matches!(call.admission, CallAdmission::Claimed)
        {
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
        if self.call_steps_settled(handle, id)? == Some(false) {
            return Err(CoreError::Busy);
        }
        let call = self
            .owned_mut(handle)?
            .calls
            .get_mut(id)
            .ok_or(CoreError::StaleOwner)?;
        if call.outcome.is_some() {
            return Err(CoreError::AlreadyCompleted);
        }
        call.outcome = Some(outcome);
        self.retire_call_steps(handle, id)?;
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
        if !interrupted && run.agent.as_ref().is_some_and(|agent| !agent.terminal()) {
            return Err(CoreError::Busy);
        }
        if !interrupted && run.calls.values().any(|call| call.outcome.is_none()) {
            return Err(CoreError::Busy);
        }
        if !interrupted && run.steps.values().any(|step| !step.settled()) {
            return Err(CoreError::Busy);
        }
        let mut results = Vec::new();
        for id in &run.call_order {
            let call = run.calls.get(id).ok_or(CoreError::StaleOwner)?;
            let outcome = call.outcome.unwrap_or(
                if call.started && call.safety != Some(ToolSafetyLevel::SafeReadOnly) {
                    ToolOutcome::OutcomeUnknown
                } else if handle.deadline.expired() {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                },
            );
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
        if handle.scope.purpose() == RunPurpose::AgentTurn {
            let history = self
                .histories
                .get_mut(handle.scope.session_id())
                .ok_or(CoreError::StaleOwner)?;
            if !interrupted && !history.settled() {
                return Err(CoreError::Busy);
            }
            if interrupted {
                let fallback = if handle.deadline.expired() {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                };
                history.repair_missing(&completion.tool_results, fallback)?;
            }
        }
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
        self.prune_retired_histories();
        Ok(completion)
    }
}
impl Drop for ApplicationActor {
    fn drop(&mut self) {
        self.revoke_preparing(None);
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

impl RunCompletion {
    /// Idempotently repaired call results; wire-family serialization is later work.
    pub fn tool_results(&self) -> &Vec<ToolResult> {
        &self.tool_results
    }
}

impl RunSettings {
    /// The `workspace` field.
    pub(crate) fn workspace(&self) -> &Workspace {
        &self.workspace
    }
}
