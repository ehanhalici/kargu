//! Foreground claim before workspace/config/credential preparation.
//! An unprepared claim cannot execute tools; only a consuming prepared adoption
//! can produce the existing unforgeable RunHandle.

use super::{
    ActiveRun, ApplicationActor, Mode, Resources, RunHandle, RunLease, RunPurpose, RunScope,
    RunSettings,
};
use crate::{
    constants::limits,
    domain::{
        ClaimId, ConfigRevision, Deadline, ExecutionTimeout, PolicyRevision, RunId, SessionId,
        ToolCallLimit,
    },
    error::CoreError,
    security::{ToolRegistry, Workspace},
};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

/// Explicit requested root. Parsing is lexical and performs no filesystem IO.
#[derive(Clone)]
pub struct RequestedWorkspace(PathBuf);
impl TryFrom<PathBuf> for RequestedWorkspace {
    type Error = CoreError;
    fn try_from(value: PathBuf) -> Result<Self, CoreError> {
        crate::workspace::command::validate_path(&value)?;
        if !value.is_absolute() || value.to_str().is_none() {
            return Err(CoreError::Rejected);
        }
        Ok(Self(value))
    }
}

/// Immutable pre-admission intent. It contains no credential or resolved network authority.
pub struct ClaimIntent {
    /// Operating mode captured before any asynchronous preparation.
    pub mode: Mode,
    /// Explicit lexical workspace intent, later pinned on a bounded worker.
    pub workspace: RequestedWorkspace,
    /// Maximum native invocation count for the real agent run.
    pub tool_limit: ToolCallLimit,
    /// Absolute execution lifetime begins at claim acquisition, not after preparation.
    pub timeout: ExecutionTimeout,
    /// Captured configuration revision.
    pub config_revision: ConfigRevision,
    /// Captured permission policy revision.
    pub policy_revision: PolicyRevision,
}

/// Unforgeable preparation owner. It grants no process/editor execution rights.
#[derive(Clone)]
pub struct RunClaim {
    scope: RunScope,
    intent: Arc<ClaimIntent>,
    deadline: Deadline,
    resources: Arc<Resources>,
    preparation: CancellationToken,
    registry: Arc<ToolRegistry>,
}
impl RunClaim {
    /// Native definitions frozen before any asynchronous preparation begins.
    pub fn tool_registry(&self) -> &ToolRegistry {
        &self.registry
    }
    /// Stable application/session/run/generation identity, preserved on activation.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Captured immutable mode; live UI selection cannot retarget this claim.
    pub fn mode(&self) -> Mode {
        self.intent.mode
    }
    /// Original absolute deadline; preparation cannot extend it by completing late.
    pub fn deadline(&self) -> Deadline {
        self.deadline
    }
    /// Child cancellation for asynchronous preparation; cancelling it cannot cancel a sibling.
    pub fn cancellation(&self) -> CancellationToken {
        self.preparation.child_token()
    }
    /// Reject cancelled, superseded or expired preparation.
    pub fn check_live(&self) -> Result<(), CoreError> {
        if self.preparation.is_cancelled() || self.resources.cancellation.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if self.deadline.expired() {
            return Err(CoreError::Deadline);
        }
        Ok(())
    }
    /// All acquired preparation resources have actually completed.
    pub fn drained(&self) -> bool {
        self.resources.pending.load(Ordering::Acquire) == 0
    }
    fn same_owner(&self, other: &Self) -> bool {
        self.scope == other.scope && Arc::ptr_eq(&self.resources, &other.resources)
    }
    /// Acquire a native resource lease before starting config, credential or context work.
    /// Keep it through actual worker/adapter join, even after cancellation.
    pub fn lease(&self) -> Result<ClaimLease, CoreError> {
        self.check_live()?;
        self.resources
            .pending
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                count.checked_add(1)
            })
            .map_err(|_| CoreError::ArithmeticOverflow)?;
        let lease = ClaimLease {
            _lease: RunLease {
                resources: self.resources.clone(),
            },
        };
        self.check_live()?;
        Ok(lease)
    }
    /// Capture and revalidate the requested workspace on a bounded worker.
    /// The returned consuming value retains that worker lease through actor adoption.
    pub fn prepare_workspace(&self) -> Result<PreparedRun, CoreError> {
        let lease = self.lease()?;
        let workspace = Workspace::try_from(self.intent.workspace.0.clone())?;
        self.check_live()?;
        workspace.revalidate()?;
        let settings = match self.intent.timeout.duration() {
            Some(timeout) => RunSettings::new(
                self.intent.mode,
                workspace,
                self.intent.tool_limit,
                timeout,
                self.intent.config_revision,
                self.intent.policy_revision,
            )?,
            None => RunSettings::persistent(
                self.intent.mode,
                workspace,
                self.intent.tool_limit,
                self.intent.config_revision,
                self.intent.policy_revision,
            ),
        };
        self.check_live()?;
        Ok(PreparedRun {
            claim: self.clone(),
            settings,
            lease,
        })
    }
}

/// One preparation resource. Dropping an observer must not drop a still-running worker's lease.
#[must_use = "Hold the preparation lease until the actual operation has joined"]
pub struct ClaimLease {
    _lease: RunLease,
}

/// Consuming workspace preparation result. No DTO or run ID can manufacture one.
/// ```compile_fail
/// use kargu_core::application::PreparedRun;
/// let forged = PreparedRun {};
/// ```
pub struct PreparedRun {
    claim: RunClaim,
    settings: RunSettings,
    lease: ClaimLease,
}

pub(super) enum ClaimState {
    Preparing,
    Draining,
}
pub(super) struct PendingClaim {
    pub claim: RunClaim,
    pub state: ClaimState,
}

impl ApplicationActor {
    /// Claim the application before workspace/config/credential/network preparation.
    /// This only mutates actor memory; no root metadata, disk or network is touched.
    pub fn claim_run(
        &mut self,
        session: &SessionId,
        intent: ClaimIntent,
    ) -> Result<RunClaim, CoreError> {
        self.check_admission()?;
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        if self.active.is_some()
            || self.preparing.is_some()
            || self.history_imports.owns_session(session)
        {
            return Err(CoreError::Busy);
        }
        if !self.session_history(session)?.settled() {
            return Err(CoreError::Busy);
        }
        let generation = self.generation.next()?;
        let deadline = intent.timeout.start()?;
        let claim = RunClaim {
            registry: self.registry.clone(),
            scope: RunScope {
                purpose: RunPurpose::AgentTurn,
                application_id: self.id.clone(),
                session_id: session.clone(),
                run_id: RunId::new(),
                claim_id: ClaimId::new(),
                generation,
                config_revision: intent.config_revision,
                policy_revision: intent.policy_revision,
            },
            intent: Arc::new(intent),
            deadline,
            resources: Arc::new(Resources {
                cancellation: CancellationToken::new(),
                pending: AtomicUsize::new(0),
                process_slots: Arc::new(Semaphore::new(limits::RUN_PROCESSES)),
                output: AtomicUsize::new(0),
            }),
            preparation: CancellationToken::new(),
        };
        self.generation = generation;
        self.preparing = Some(PendingClaim {
            claim: claim.clone(),
            state: ClaimState::Preparing,
        });
        Ok(claim)
    }

    /// Adopt a completed workspace without filesystem IO, preserving the early claim identity.
    /// Other outstanding preparations must join before model/tool effects can begin.
    pub fn activate_claim(&mut self, prepared: PreparedRun) -> Result<RunHandle, CoreError> {
        let pending = self.preparing.as_ref().ok_or(CoreError::StaleOwner)?;
        if !pending.claim.same_owner(&prepared.claim)
            || !matches!(pending.state, ClaimState::Preparing)
            || !self.owns_session(prepared.claim.scope.session_id())
            || self.active.is_some()
        {
            return Err(CoreError::StaleOwner);
        }
        prepared.claim.check_live()?;
        if prepared.claim.resources.pending.load(Ordering::Acquire) != 1 {
            return Err(CoreError::Busy);
        }
        let PreparedRun {
            claim,
            settings,
            lease,
        } = prepared;
        // No actor yield separates the final resource check, lease release and adoption.
        drop(lease);
        claim.preparation.cancel();
        let handle = RunHandle {
            registry: claim.registry,
            scope: claim.scope,
            settings,
            deadline: claim.deadline,
            resources: claim.resources,
        };
        self.preparing = None;
        self.active = Some(ActiveRun {
            steps: HashMap::new(),
            agent: None,
            handle: handle.clone(),
            calls: HashMap::new(),
            call_order: Vec::new(),
            spent: crate::domain::StepCount::ZERO,
            cleanup_failed: false,
        });
        Ok(handle)
    }

    /// Revoke one preparing owner immediately; it still blocks replacement admission.
    pub fn cancel_claim(&mut self, claim: &RunClaim) -> Result<(), CoreError> {
        let pending = self.preparing.as_mut().ok_or(CoreError::StaleOwner)?;
        if !pending.claim.same_owner(claim) {
            return Err(CoreError::StaleOwner);
        }
        pending.state = ClaimState::Draining;
        pending.claim.resources.cancellation.cancel();
        pending.claim.preparation.cancel();
        Ok(())
    }

    /// Release only after actual preparation drain. A stale claim cannot release another run.
    pub fn finish_claim(&mut self, claim: &RunClaim) -> Result<(), CoreError> {
        self.cancel_claim(claim)?;
        if !claim.drained() {
            return Err(CoreError::Busy);
        }
        self.preparing = None;
        self.prune_retired_histories();
        Ok(())
    }

    pub(super) fn revoke_preparing(&mut self, session: Option<&SessionId>) {
        if let Some(pending) = &mut self.preparing
            && session.is_none_or(|session| pending.claim.scope.session_id() == session)
        {
            pending.state = ClaimState::Draining;
            pending.claim.resources.cancellation.cancel();
            pending.claim.preparation.cancel();
        }
    }
}
