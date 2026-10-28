//! Editor actions share the command approval map, but can never become commands.
use super::{ActionDigest, CapturedAction, ExecutionGate, PendingApproval, ToolRegistry};
use crate::{
    application::{ApplicationActor, RunHandle, RunLease, RunScope, ToolOutcome},
    constants::{limits, timeouts},
    domain::{ApprovalId, ToolCallId, ToolName, ToolSafetyLevel},
    edit::{
        intent::EditorAction,
        types::{EditorRevision, ReviewMode},
    },
    error::CoreError,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::time::Instant;

/// Actual review-presenter availability captured by the trusted editor adapter.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EditorPresenter {
    /// Interactive review can be presented.
    Available,
    /// Interactive review cannot be presented; never consent.
    Missing,
}
/// Exact revision decision. Revised text requires a newly prepared native action.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EditorDecision {
    /// Accept exactly the indicated immutable revision.
    Accept,
    /// Explicit refusal.
    Reject,
    /// Explicit interruption.
    Interrupt,
}
/// Immutable editor review information; no executable/argv placeholder exists.
pub struct EditorApprovalRequest {
    id: ApprovalId,
    scope: RunScope,
    digest: ActionDigest,
    deadline: Instant,
    revision: EditorRevision,
    mode: ReviewMode,
    metadata: Value,
}
impl EditorApprovalRequest {
    /// One pending entry in the same ledger used by commands.
    pub fn id(&self) -> &ApprovalId {
        &self.id
    }
    /// Actual native application/session/run/generation/revision scope.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Commitment to the immutable action and actual admitted run.
    pub fn digest(&self) -> &ActionDigest {
        &self.digest
    }
    /// Native decision deadline, capped by the owning run.
    pub fn deadline(&self) -> Instant {
        self.deadline
    }
    /// The only review revision this request can authorize.
    pub fn revision(&self) -> EditorRevision {
        self.revision
    }
    /// Frozen async/blocking review behavior.
    pub fn review_mode(&self) -> ReviewMode {
        self.mode
    }
    /// Explicit source-free review metadata; source text is not implicitly logged.
    pub fn metadata(&self) -> &Value {
        &self.metadata
    }
}
/// Owned admission input from the trusted native preparation/editor boundary.
pub struct EditorAdmissionInput {
    /// Actual tool-call identity registered with the owning run.
    pub call_id: ToolCallId,
    /// Immutable prepared intent; ownership transfers to the shared ledger.
    pub action: EditorAction,
    /// Captured availability of the editor review presenter.
    pub presenter: EditorPresenter,
}
/// Result of native policy admission; auto and interactive decisions stay distinct.
pub enum EditorAdmission {
    /// Captured auto policy authorized an immutable intent.
    Authorized(AuthorizedEditorEdit),
    /// Async/blocking policy awaits explicit consent.
    Review(EditorApprovalRequest),
}
/// Consuming editor authorization, not an issued write or proof of completed IO.
/// Journal issuance and live preflight must precede the later editor effect port.
/// ```compile_fail
/// use kargu_core::security::AuthorizedEditorEdit;
/// fn replay(grant: AuthorizedEditorEdit) { let _copy = grant.clone(); }
/// ```
/// ```compile_fail
/// use kargu_core::security::AuthorizedEditorEdit;
/// let forged = AuthorizedEditorEdit {};
/// ```
pub struct AuthorizedEditorEdit {
    run: RunHandle,
    call_id: ToolCallId,
    action: Box<EditorAction>,
    lease: RunLease,
    deadline: Instant,
}
impl AuthorizedEditorEdit {
    /// The authorization's actual execution owner.
    pub fn scope(&self) -> &RunScope {
        self.run.scope()
    }
    /// The frozen native review revision.
    pub fn revision(&self) -> EditorRevision {
        self.action.revision()
    }
    /// Explicitly access the immutable intent at a trusted adapter boundary.
    pub fn action(&self) -> &EditorAction {
        &self.action
    }
    /// Recheck owner/mode/deadline without performing filesystem IO on the actor.
    pub fn revalidate(&self, actor: &ApplicationActor) -> Result<(), CoreError> {
        actor.validate(&self.run)?;
        if Instant::now() >= self.deadline {
            return Err(CoreError::ApprovalExpired);
        }
        if !self.action.matches_run(&self.run) {
            return Err(CoreError::StaleOwner);
        }
        Ok(())
    }
    pub(crate) fn expire_unissued(self, actor: &mut ApplicationActor) -> Result<(), CoreError> {
        actor.validate_owner(&self.run)?;
        actor.complete_tool(&self.run, &self.call_id, ToolOutcome::Timeout)?;
        drop(self.lease);
        Ok(())
    }
    /// Cancel an authorization before any journalled issuance. No applied result is fabricated.
    pub fn cancel_unissued(self, actor: &mut ApplicationActor) -> Result<(), CoreError> {
        actor.validate_owner(&self.run)?;
        let outcome = if Instant::now() >= self.deadline {
            ToolOutcome::Timeout
        } else {
            ToolOutcome::Cancelled
        };
        actor.complete_tool(&self.run, &self.call_id, outcome)?;
        drop(self.lease);
        Ok(())
    }
}
fn digest(
    run: &RunHandle,
    name: &ToolName,
    action: &EditorAction,
) -> Result<ActionDigest, CoreError> {
    let mut hash = Sha256::new();
    hash.update(b"kargu-editor-v1");
    let scope = serde_json::to_vec(run.scope()).map_err(|_| CoreError::InvalidToolOutput)?;
    for bytes in [
        scope.as_slice(),
        name.as_str().as_bytes(),
        action.commitment().as_slice(),
    ] {
        hash.update(
            u64::try_from(bytes.len())
                .map_err(|_| CoreError::ArithmeticOverflow)?
                .to_le_bytes(),
        );
        hash.update(bytes);
    }
    Ok(ActionDigest(hash.finalize().into()))
}
impl ExecutionGate {
    /// Admit an editor intent through the shared ledger. Hashes/client IDs alone never consent.
    pub fn admit_editor(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        registry: &ToolRegistry,
        requested: &ToolName,
        input: EditorAdmissionInput,
    ) -> Result<EditorAdmission, CoreError> {
        let EditorAdmissionInput {
            call_id,
            action,
            presenter,
        } = input;
        actor.validate(run)?;
        let descriptor = registry.resolve(requested)?;
        if descriptor.safety() != ToolSafetyLevel::MutatesState
            || !action.matches_run(run)
            || !action.permits_deletion()
        {
            return Err(CoreError::Rejected);
        }
        let mode = action.review_mode();
        if mode != ReviewMode::Auto && presenter == EditorPresenter::Missing {
            return Err(CoreError::Unavailable);
        }
        if self.pending.len() >= limits::MAX_PENDING {
            return Err(CoreError::Limit);
        }
        let action_digest = digest(run, descriptor.name(), &action)?;
        let deadline = run.deadline().cap(
            Instant::now()
                .checked_add(timeouts::APPROVAL)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let lease = run.lease()?;
        actor.register_call(run, call_id.clone(), descriptor.name().clone())?;
        let id = ApprovalId::new();
        let request = EditorApprovalRequest {
            id: id.clone(),
            scope: run.scope().clone(),
            digest: action_digest.clone(),
            deadline,
            revision: action.revision(),
            mode,
            metadata: action.metadata().clone(),
        };
        self.pending.insert(
            id,
            PendingApproval {
                run: run.clone(),
                call_id,
                name: descriptor.name().clone(),
                action: CapturedAction::Editor(Box::new(action)),
                digest: action_digest,
                deadline,
                lease,
            },
        );
        if mode == ReviewMode::Auto {
            let revision = request.revision();
            self.decide_editor(actor, run, &request, revision, EditorDecision::Accept)
                .map(EditorAdmission::Authorized)
        } else {
            Ok(EditorAdmission::Review(request))
        }
    }
    /// Consume exactly one matching native revision; foreign/stale decisions leave it pending.
    pub fn decide_editor(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        request: &EditorApprovalRequest,
        revision: EditorRevision,
        decision: EditorDecision,
    ) -> Result<AuthorizedEditorEdit, CoreError> {
        actor.validate(run)?;
        let pending = self
            .pending
            .get(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        if !pending.run.same_owner(run)
            || request.scope != *run.scope()
            || pending.digest != request.digest
            || request.revision != revision
        {
            return Err(CoreError::StaleOwner);
        }
        let CapturedAction::Editor(action) = &pending.action else {
            return Err(CoreError::Rejected);
        };
        if action.revision() != revision {
            return Err(CoreError::StaleOwner);
        }
        let pending = self
            .pending
            .remove(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        let CapturedAction::Editor(action) = pending.action else {
            return Err(CoreError::Rejected);
        };
        let validation = if Instant::now() >= pending.deadline {
            Err(CoreError::ApprovalExpired)
        } else if decision == EditorDecision::Reject {
            Err(CoreError::Rejected)
        } else if decision == EditorDecision::Interrupt {
            Err(CoreError::Cancelled)
        } else if !action.matches_run(run) || digest(run, &pending.name, &action)? != pending.digest
        {
            Err(CoreError::StaleOwner)
        } else {
            Ok(())
        };
        if let Err(error) = validation {
            let outcome = match error {
                CoreError::ApprovalExpired => ToolOutcome::Timeout,
                CoreError::Cancelled => ToolOutcome::Cancelled,
                _ => ToolOutcome::Rejected,
            };
            actor.complete_tool(run, &pending.call_id, outcome)?;
            return Err(error);
        }
        Ok(AuthorizedEditorEdit {
            run: pending.run,
            call_id: pending.call_id,
            action,
            lease: pending.lease,
            deadline: pending.deadline,
        })
    }
}
