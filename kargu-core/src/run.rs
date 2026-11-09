//! The run model: captured settings, the unforgeable run handle and its
//! leases, the run's identity scope and the terminal classification of the
//! tools it executed.
//!
//! Every module that executes on behalf of a run depends on this model; the
//! application actor that admits and releases runs builds on it.

use crate::{
    constants::limits,
    domain::*,
    error::CoreError,
    policy::{ToolRegistry, Workspace},
};
use serde::{Deserialize, Serialize};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

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
impl PreparedEditorSettings {
    /// The revalidated settings, consumed by editor admission.
    pub(crate) fn into_settings(self) -> RunSettings {
        self.0
    }
}
impl RunSettings {
    pub(crate) fn prepare_editor(self) -> Result<PreparedEditorSettings, CoreError> {
        self.workspace.revalidate()?;
        Ok(PreparedEditorSettings(self))
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
    /// A fresh run and claim identity for an owner at a lineage of revisions.
    pub(crate) fn new(
        purpose: RunPurpose,
        owner: (ApplicationId, SessionId),
        lineage: (Generation, ConfigRevision, PolicyRevision),
    ) -> Self {
        let (application_id, session_id) = owner;
        let (generation, config_revision, policy_revision) = lineage;
        Self {
            purpose,
            application_id,
            session_id,
            run_id: RunId::new(),
            claim_id: ClaimId::new(),
            generation,
            config_revision,
            policy_revision,
        }
    }
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

/// Shared revocation, lease accounting and process slots of one run.
pub(crate) struct Resources {
    cancellation: CancellationToken,
    pending: AtomicUsize,
    process_slots: Arc<Semaphore>,
    output: AtomicUsize,
}
impl Resources {
    /// Fresh, unrevoked resources with no outstanding lease.
    pub(crate) fn fresh() -> Arc<Self> {
        Arc::new(Self {
            cancellation: CancellationToken::new(),
            pending: AtomicUsize::new(0),
            process_slots: Arc::new(Semaphore::new(limits::RUN_PROCESSES)),
            output: AtomicUsize::new(0),
        })
    }
    /// Revoke every lease holder's execution and publication rights.
    pub(crate) fn cancel(&self) {
        self.cancellation.cancel();
    }
    /// Refuse once revoked.
    pub(crate) fn live(&self) -> Result<(), CoreError> {
        if self.cancellation.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        Ok(())
    }
    /// Succeed only when no lease or undelivered completion is outstanding.
    pub(crate) fn settled(&self) -> Result<(), CoreError> {
        match self.pending.load(Ordering::Acquire) {
            0 => Ok(()),
            _ => Err(CoreError::Busy),
        }
    }
    /// Succeed only when exactly the caller's own lease is outstanding.
    pub(crate) fn solely_leased(&self) -> Result<(), CoreError> {
        match self.pending.load(Ordering::Acquire) {
            1 => Ok(()),
            _ => Err(CoreError::Busy),
        }
    }
    /// Count one more outstanding lease; dropping it releases the count.
    pub(crate) fn lease(self: &Arc<Self>) -> Result<RunLease, CoreError> {
        self.pending
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
            .map_err(|_| CoreError::ArithmeticOverflow)?;
        Ok(RunLease {
            resources: self.clone(),
        })
    }
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
    /// Bind a captured scope and settings to their deadline, resources and catalog.
    pub(crate) fn new(
        scope: RunScope,
        settings: RunSettings,
        held: (Deadline, Arc<Resources>, Arc<ToolRegistry>),
    ) -> Self {
        let (deadline, resources, registry) = held;
        Self {
            scope,
            settings,
            deadline,
            resources,
            registry,
        }
    }
    /// Revoke this run's execution and publication rights.
    pub(crate) fn cancel(&self) {
        self.resources.cancel();
    }
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
        let lease = self.resources.lease()?;
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

impl ToolResult {
    /// The result for a call settled with `outcome`; its notice follows from it.
    pub(crate) fn new(tool_call_id: ToolCallId, tool_name: ToolName, outcome: ToolOutcome) -> Self {
        Self {
            tool_call_id,
            tool_name,
            is_error: outcome != ToolOutcome::Ok,
            message: outcome.summary(),
            outcome,
        }
    }
}

/// Released run, with exactly one result for every registered call.
#[derive(Debug, Serialize)]
pub struct RunCompletion {
    /// Released run scope.
    scope: RunScope,
    /// Idempotently repaired call results; wire-family serialization is later work.
    tool_results: Vec<ToolResult>,
}

impl RunCompletion {
    /// Exactly one result per registered call of the released `scope`.
    pub(crate) fn new(scope: RunScope, tool_results: Vec<ToolResult>) -> Self {
        Self {
            scope,
            tool_results,
        }
    }
    /// Idempotently repaired call results; wire-family serialization is later work.
    pub fn tool_results(&self) -> &Vec<ToolResult> {
        &self.tool_results
    }
}

impl RunSettings {
    /// Deadline policy captured for the run.
    pub(crate) fn timeout(&self) -> ExecutionTimeout {
        self.timeout
    }
    /// Configuration revision frozen at capture.
    pub(crate) fn config_revision(&self) -> ConfigRevision {
        self.config_revision
    }
    /// Policy revision frozen at capture.
    pub(crate) fn policy_revision(&self) -> PolicyRevision {
        self.policy_revision
    }
    /// Tool-call budget captured for the run.
    pub(crate) fn tool_limit(&self) -> ToolCallLimit {
        self.tool_limit
    }
    /// The `workspace` field.
    pub(crate) fn workspace(&self) -> &Workspace {
        &self.workspace
    }
}

/// Outcome of admitting a post-edit diagnostic delta into a bounded healing turn.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealingVerdict {
    /// Eligible new errors admitted for a bounded healing turn under parent run.
    Admitted {
        /// 1-based healing round number (`1..=AGENT_HEALING_ROUNDS`).
        round: std::num::NonZeroU8,
    },
    /// Identical new error set repeated across healing rounds (doom-loop cap).
    RepeatedErrors,
    /// Healing round cap (`AGENT_HEALING_ROUNDS`) or turn limit exhausted.
    BudgetExhausted,
}

/// The application ledger an execution gate or process supervisor settles
/// against: call and step admission, start and terminal outcome of one run.
///
/// The application actor implements it; gates and supervisors receive this
/// port, never the actor, so they stay below the application they serve.
pub trait RunLedger {
    /// Confirm `run` is this application's live run.
    fn validate(&self, run: &RunHandle) -> Result<(), CoreError>;
    /// Confirm `run` belongs to this application, live or draining.
    fn validate_owner(&self, run: &RunHandle) -> Result<(), CoreError>;
    /// Register the step `call` and `tool` of an already committed parent call.
    fn claim_step(
        &mut self,
        run: &RunHandle,
        call: (&ToolCallId, &ToolStepId),
        tool: (&ToolName, ToolSafetyLevel),
    ) -> Result<(), CoreError>;
    /// Reserve a new call `id` of `tool` against the run's tool budget.
    fn reserve_call(
        &mut self,
        run: &RunHandle,
        id: ToolCallId,
        tool: (ToolName, ToolSafetyLevel),
    ) -> Result<(), CoreError>;
    /// Record that `action` began its effects.
    fn mark_action_started(
        &mut self,
        run: &RunHandle,
        action: (&ToolCallId, Option<&ToolStepId>),
    ) -> Result<(), CoreError>;
    /// Settle `action` with its terminal `outcome`.
    fn complete_action(
        &mut self,
        run: &RunHandle,
        action: (&ToolCallId, Option<&ToolStepId>),
        outcome: ToolOutcome,
    ) -> Result<(), CoreError>;
    /// Commit the history result of call `id`.
    fn complete_history_call(
        &mut self,
        run: &RunHandle,
        id: &ToolCallId,
        result: (ToolOutcome, &str),
    ) -> Result<MessageId, CoreError>;
    /// Quarantine a run whose effects can no longer be established.
    fn quarantine(&mut self, run: &RunHandle) -> Result<(), CoreError>;
}
