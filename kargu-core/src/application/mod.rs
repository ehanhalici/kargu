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

use crate::{constants::limits, domain::*, error::CoreError, policy::ToolRegistry};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};

pub use crate::domain::Mode;
pub(crate) use crate::run::{PreparedEditorSettings, Resources, RunLease};
pub use crate::run::{
    RunCompletion, RunHandle, RunPurpose, RunScope, RunSettings, ToolOutcome, ToolResult,
};

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
        let run =
            self.capture_owned_run(session, settings.into_settings(), RunPurpose::EditorEdit)?;
        let handle = run.handle.clone();
        self.editor_runs
            .insert(handle.scope().run_id().clone(), run);
        Ok(handle)
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
            .any(|run| run.handle.scope().session_id() == session)
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
            if run.handle.scope().session_id() == session {
                run.handle.cancel();
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
            run.handle.cancel();
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
        settings.workspace().revalidate()?;
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
        let deadline = settings.timeout().start()?;
        let scope = RunScope::new(
            purpose,
            (self.id.clone(), session.clone()),
            (
                generation,
                settings.config_revision(),
                settings.policy_revision(),
            ),
        );
        let handle = RunHandle::new(
            scope,
            settings,
            (deadline, Resources::fresh(), self.registry.clone()),
        );
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
                    .get(handle.scope().run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .or_else(|| {
                self.editor_runs
                    .get(handle.scope().run_id())
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
                    .get_mut(handle.scope().run_id())
                    .filter(|r| r.handle.same_owner(handle))
            })
            .or_else(|| {
                self.editor_runs
                    .get_mut(handle.scope().run_id())
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
        if !handle.settings().tool_limit().permits(run.spent) {
            return Err(CoreError::BudgetExceeded {
                limit: handle.settings().tool_limit(),
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
        handle.cancel();
        Ok(())
    }
    /// Revoke rights first. The claim remains owned until resources drain and repair finishes.
    pub fn cancel(&mut self, handle: &RunHandle) -> Result<(), CoreError> {
        self.owned(handle)?.handle.cancel();
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
                } else if handle.deadline().expired() {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                },
            );
            results.push(ToolResult::new(id.clone(), call.name.clone(), outcome));
        }
        let completion = RunCompletion::new(handle.scope().clone(), results);
        if handle.scope().purpose() == RunPurpose::AgentTurn {
            let history = self
                .histories
                .get_mut(handle.scope().session_id())
                .ok_or(CoreError::StaleOwner)?;
            if !interrupted && !history.settled() {
                return Err(CoreError::Busy);
            }
            if interrupted {
                let fallback = if handle.deadline().expired() {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                };
                history.repair_missing(completion.tool_results(), fallback)?;
            }
        }
        handle.cancel();
        match handle.scope().purpose() {
            RunPurpose::AgentTurn => self.active = None,
            RunPurpose::ProcessJob => {
                self.job_runs.remove(handle.scope().run_id());
            }
            RunPurpose::EditorEdit => {
                self.editor_runs.remove(handle.scope().run_id());
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
            run.handle.cancel();
        }
    }
}
