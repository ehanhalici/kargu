//! Live editor calls consume the same native approval ledger as process and edit actions.
//! A resource stamp is revalidated by the editor immediately before any actual effect.

use super::{
    ActionDigest, CapturedAction, EditorPresenter, ExecutionGate, PendingApproval,
    RegistryRevision, ToolDescriptor, ToolRegistry, ToolRoute, UserDecision,
};
use crate::{
    application::{ApplicationActor, RunHandle, RunLease, RunScope, ToolOutcome},
    constants::{limits, timeouts},
    domain::{ApprovalId, MessageId, ToolCallId, ToolName, ToolSafetyLevel, ToolStepId},
    error::CoreError,
    sensors::{
        diagnostics::DocumentStamp,
        symbols::LanguageSource,
        types::{DebugConnectionId, FrameId, StopGeneration, ThreadId},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json, value::RawValue};
use sha2::{Digest, Sha256};
use std::{path::PathBuf, sync::Arc};
use tokio::time::Instant;

/// Exact runtime resource captured before an editor invocation.
#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum EditorResource {
    /// Project operation bound to the run's explicit workspace, without a current-buffer fallback.
    Workspace {},
    /// An exact live document, including unsaved modification tick.
    Document {
        /// Source path, document identity and captured tick.
        document: DocumentStamp,
    },
    /// A document bound to the same live language provider and LSP version.
    LanguageDocument {
        /// Exact source document, including unsaved text revision.
        document: DocumentStamp,
        /// Captured imenu provider or Eglot connection/version/encoding.
        source: LanguageSource,
    },
    /// Debugger references are valid only within this connection/stop/thread/frame.
    Debugger {
        /// Actual editor connection identity.
        connection_id: DebugConnectionId,
        /// Captured stop epoch, invalidated by continue/restart/replacement.
        stop_generation: StopGeneration,
        /// Captured thread, absent only for connection-level/running operations.
        thread_id: Option<ThreadId>,
        /// Captured frame, absent only when the operation needs no paused frame.
        frame_id: Option<FrameId>,
    },
}

/// Parsed immutable editor action. Prepare on a bounded worker before actor admission.
/// Its construction cannot register a call, acquire consent or execute an adapter.
pub struct PreparedEditorTool {
    scope: RunScope,
    root: PathBuf,
    call_id: ToolCallId,
    descriptor: ToolDescriptor,
    registry_revision: RegistryRevision,
    arguments: Arc<RawValue>,
    resource: EditorResource,
    digest: ActionDigest,
}
impl PreparedEditorTool {
    /// Validate one trusted registry snapshot and detached resource/argument observation.
    pub fn prepare(
        run: &RunHandle,
        registry: &ToolRegistry,
        requested: &ToolName,
        call_id: ToolCallId,
        arguments: Value,
        resource: EditorResource,
    ) -> Result<Self, CoreError> {
        run.check_live()?;
        run.settings().workspace().revalidate()?;
        let descriptor = registry.resolve(requested)?;
        let metadata = descriptor.presentation().ok_or(CoreError::Unavailable)?;
        if metadata.route() != ToolRoute::Editor || !descriptor.permits_mode(run.settings().mode) {
            return Err(CoreError::Rejected);
        }
        metadata.parameters().validate(&arguments)?;
        check_resource(descriptor.name(), &resource, &arguments)?;
        if let EditorResource::Document { document }
        | EditorResource::LanguageDocument { document, .. } = &resource
            && let Some(path) = arguments.get("file_path").and_then(Value::as_str)
        {
            let path = std::path::Path::new(path);
            let relative = if path.is_absolute() {
                path.strip_prefix(run.settings().workspace().path())
                    .map_err(|_| CoreError::Rejected)?
            } else {
                path
            };
            let path = crate::edit::types::EditPath::try_from(
                relative.to_str().ok_or(CoreError::Rejected)?.to_owned(),
            )?;
            if path != document.path {
                return Err(CoreError::StaleOwner);
            }
        }
        let arguments = serde_json::value::to_raw_value(&arguments)
            .map_err(|_| CoreError::InvalidToolOutput)?;
        if arguments.get().len() > limits::EDITOR_TOOL_ARGUMENT_BYTES {
            return Err(CoreError::Limit);
        }
        let root = run.settings().workspace().path().to_path_buf();
        let digest = serde_json::to_vec(&json!({"scope":run.scope(),"root":root,
            "call_id":call_id,"tool_name":descriptor.name(),"registry_revision":registry.revision(),
            "arguments":arguments,"resource":resource}))
        .map_err(|_| CoreError::InvalidToolOutput)?;
        Ok(Self {
            scope: run.scope().clone(),
            root,
            call_id,
            descriptor: descriptor.clone(),
            registry_revision: registry.revision(),
            arguments: Arc::from(arguments),
            resource,
            digest: ActionDigest(Sha256::digest(digest).into()),
        })
    }
    fn matches_run(&self, run: &RunHandle) -> bool {
        &self.scope == run.scope()
            && self.root == run.settings().workspace().path()
            && self.descriptor.permits_mode(run.settings().mode)
    }
    /// Canonical tool identity, after native alias resolution.
    pub fn name(&self) -> &ToolName {
        self.descriptor.name()
    }
    /// Unchanged parsed argument object; access only at explicit editor/model boundaries.
    pub fn arguments(&self) -> &RawValue {
        self.arguments.as_ref()
    }
    /// Exact captured live resource to revalidate at effect entry.
    pub fn resource(&self) -> &EditorResource {
        &self.resource
    }
    /// Native catalog generation captured in the action digest.
    pub fn registry_revision(&self) -> RegistryRevision {
        self.registry_revision
    }
    /// Actual executor effect class, independent of model-provided schema text.
    pub fn safety(&self) -> ToolSafetyLevel {
        self.descriptor.safety()
    }
}

fn check_resource(
    name: &ToolName,
    resource: &EditorResource,
    arguments: &Value,
) -> Result<(), CoreError> {
    let allowed = match name.as_str() {
        "debug_start"
        | "debug_list_breakpoints"
        | "debug_set_breakpoint"
        | "debug_clear_breakpoint"
        | "debug_toggle_breakpoint" => matches!(
            resource,
            EditorResource::Workspace {} | EditorResource::Debugger { .. }
        ),
        "debug_pause" | "debug_threads" | "debug_modules" | "debug_sources" | "debug_restart"
        | "debug_kill" | "debug_disconnect" | "debug_quit" => {
            matches!(resource, EditorResource::Debugger { .. })
        }
        "debug_continue" | "debug_step_in" | "debug_step_out" | "debug_step_over" => matches!(
            resource,
            EditorResource::Debugger {
                thread_id: Some(_),
                ..
            }
        ),
        "debug_get_context" | "debug_eval" | "debug_watch" | "debug_stack" | "debug_scope"
        | "debug_up" | "debug_down" => matches!(
            resource,
            EditorResource::Debugger {
                thread_id: Some(_),
                frame_id: Some(_),
                ..
            }
        ),
        "lsp_diagnostics" => {
            if arguments
                .get("file_path")
                .and_then(Value::as_str)
                .is_some_and(|path| !path.is_empty())
            {
                matches!(resource, EditorResource::Document { .. })
            } else {
                matches!(resource, EditorResource::Workspace { .. })
            }
        }
        "lsp_project_skeleton" | "lsp_find_symbol" => matches!(
            resource,
            EditorResource::Workspace {} | EditorResource::Document { .. }
        ),
        "read_file_symbols" | "read_symbol" => matches!(
            resource,
            EditorResource::LanguageDocument { .. } | EditorResource::Document { .. }
        ),
        _ => false,
    };
    if !allowed {
        return Err(CoreError::InvalidValue {
            field: "EditorResource",
        });
    }
    Ok(())
}

/// Source-free approval identity; the full immutable action stays in the shared ledger.
pub struct EditorToolApprovalRequest {
    id: ApprovalId,
    scope: RunScope,
    digest: ActionDigest,
    deadline: Instant,
}
impl EditorToolApprovalRequest {
    /// Pending shared-ledger identity.
    pub fn id(&self) -> &ApprovalId {
        &self.id
    }
    /// Exact owner/run/generation/config/policy revisions.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Commitment to the canonical tool, resource, arguments and native registry revision.
    pub fn digest(&self) -> &ActionDigest {
        &self.digest
    }
    /// Last instant at which this action may enter execution.
    pub fn deadline(&self) -> Instant {
        self.deadline
    }
}

/// Native automatic read admission or an explicit human decision requirement.
pub enum EditorToolAdmission {
    /// Safe read already authorized by the captured native policy.
    Authorized(AuthorizedEditorTool),
    /// Mutation/evaluation/control awaits exact action consent.
    Review(EditorToolApprovalRequest),
}

/// Consuming editor-call grant; it cannot become a command or a buffer-edit grant.
/// ```compile_fail
/// use kargu_core::security::AuthorizedEditorTool;
/// fn replay(grant: AuthorizedEditorTool) { let _copy = grant.clone(); }
/// ```
pub struct AuthorizedEditorTool {
    run: RunHandle,
    action: Box<PreparedEditorTool>,
    lease: RunLease,
    deadline: Instant,
    step_id: Option<ToolStepId>,
}
impl AuthorizedEditorTool {
    /// Captured action for a trusted transport to construct its bounded request.
    pub fn action(&self) -> &PreparedEditorTool {
        &self.action
    }
    /// Validate immediately before queuing the editor invocation; never reread UI selection.
    pub fn revalidate(&self, actor: &ApplicationActor) -> Result<(), CoreError> {
        actor.validate(&self.run)?;
        self.run.settings().workspace().revalidate()?;
        if Instant::now() >= self.deadline {
            return Err(CoreError::ApprovalExpired);
        }
        if !self.action.matches_run(&self.run) {
            return Err(CoreError::StaleOwner);
        }
        Ok(())
    }
    /// Enter the actual delegated request. Retain the consuming result through callback cleanup.
    pub fn issue(self, actor: &mut ApplicationActor) -> Result<IssuedEditorTool, CoreError> {
        self.revalidate(actor)?;
        actor.mark_action_started(&self.run, &self.action.call_id, self.step_id.as_ref())?;
        Ok(IssuedEditorTool {
            run: self.run,
            action: self.action,
            _lease: self.lease,
            step_id: self.step_id,
        })
    }
}

/// Issued editor resource lease. Dropping a callback is not an actual completion report.
#[must_use = "Retain the issued editor call until its adapter completion or quiescence"]
pub struct IssuedEditorTool {
    run: RunHandle,
    action: Box<PreparedEditorTool>,
    _lease: RunLease,
    step_id: Option<ToolStepId>,
}
impl IssuedEditorTool {
    /// Exact native owner that must accompany every result page and cleanup reply.
    pub fn scope(&self) -> &RunScope {
        self.run.scope()
    }
    /// Captured action. No new permission can be derived from its metadata.
    pub fn action(&self) -> &PreparedEditorTool {
        &self.action
    }
    /// Record terminal facts for a standalone call after actual adapter cleanup.
    pub fn complete(
        self,
        actor: &mut ApplicationActor,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        actor.complete_action(
            &self.run,
            &self.action.call_id,
            self.step_id.as_ref(),
            outcome,
        )
    }
    /// Atomically commit actual model-visible output and its native call result after drain.
    /// A retired owner may report facts but cannot execute another editor action.
    pub fn complete_history(
        self,
        actor: &mut ApplicationActor,
        outcome: ToolOutcome,
        text: &str,
    ) -> Result<MessageId, CoreError> {
        if self.step_id.is_some() {
            return Err(CoreError::Rejected);
        }
        actor.complete_history_call(&self.run, &self.action.call_id, outcome, text)
    }
}

impl ExecutionGate {
    /// Release one unissued delegated review without cancelling sibling actions.
    pub fn abandon_editor_tool(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        request: &EditorToolApprovalRequest,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        actor.validate_owner(run)?;
        if matches!(outcome, ToolOutcome::Ok | ToolOutcome::OutcomeUnknown) {
            return Err(CoreError::Rejected);
        }
        self.editor_tool_action(run, request)?;
        let pending = self
            .pending
            .remove(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        actor.complete_action(run, &pending.call_id, pending.step_id.as_ref(), outcome)
    }

    /// Admit one prepared editor call through the command/edit shared approval map.
    pub fn prepare_editor_tool(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        action: PreparedEditorTool,
        presenter: EditorPresenter,
    ) -> Result<EditorToolAdmission, CoreError> {
        self.prepare_editor_tool_action(actor, run, action, presenter, None)
    }
    pub(crate) fn prepare_editor_tool_action(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        action: PreparedEditorTool,
        presenter: EditorPresenter,
        step_id: Option<ToolStepId>,
    ) -> Result<EditorToolAdmission, CoreError> {
        actor.validate(run)?;
        if !action.matches_run(run) {
            return Err(CoreError::StaleOwner);
        }
        let automatic = action.safety() == ToolSafetyLevel::SafeReadOnly;
        if !automatic && presenter == EditorPresenter::Missing {
            return Err(CoreError::Unavailable);
        }
        if self.pending.len() >= limits::MAX_PENDING {
            return Err(CoreError::Limit);
        }
        let lease = run.lease()?;
        let deadline = run.deadline().cap(
            Instant::now()
                .checked_add(timeouts::APPROVAL)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        if let Some(step) = &step_id {
            actor.claim_step(run, &action.call_id, step, action.name(), action.safety())?;
        } else {
            actor.reserve_call(
                run,
                action.call_id.clone(),
                action.name().clone(),
                action.safety(),
            )?;
        }
        let id = ApprovalId::new();
        let request = EditorToolApprovalRequest {
            id: id.clone(),
            scope: run.scope().clone(),
            digest: action.digest.clone(),
            deadline,
        };
        self.pending.insert(
            id,
            PendingApproval {
                run: run.clone(),
                call_id: action.call_id.clone(),
                step_id,
                name: action.name().clone(),
                digest: action.digest.clone(),
                action: CapturedAction::Delegated(Box::new(action)),
                deadline,
                lease,
            },
        );
        if automatic {
            self.decide_editor_tool(actor, run, &request, UserDecision::Approved)
                .map(EditorToolAdmission::Authorized)
        } else {
            Ok(EditorToolAdmission::Review(request))
        }
    }
    /// Inspect the exact captured action only for its actual owner and approval identity.
    pub fn editor_tool_action(
        &self,
        run: &RunHandle,
        request: &EditorToolApprovalRequest,
    ) -> Result<&PreparedEditorTool, CoreError> {
        let pending = self
            .pending
            .get(&request.id)
            .ok_or(CoreError::ApprovalUnavailable)?;
        if !pending.run.same_owner(run)
            || request.scope != *run.scope()
            || pending.digest != request.digest
        {
            return Err(CoreError::StaleOwner);
        }
        let CapturedAction::Delegated(action) = &pending.action else {
            return Err(CoreError::Rejected);
        };
        Ok(action)
    }
    /// Consume an exact consent once. Reject/timeout settle only this call, not a sibling run.
    pub fn decide_editor_tool(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        request: &EditorToolApprovalRequest,
        decision: UserDecision,
    ) -> Result<AuthorizedEditorTool, CoreError> {
        actor.validate(run)?;
        if !self.editor_tool_action(run, request)?.matches_run(run) {
            return Err(CoreError::StaleOwner);
        }
        let pending = self
            .pending
            .remove(&request.id)
            .ok_or(CoreError::ApprovalUnavailable)?;
        let CapturedAction::Delegated(action) = pending.action else {
            return Err(CoreError::Rejected);
        };
        let refusal = if Instant::now() >= pending.deadline {
            Some((CoreError::ApprovalExpired, ToolOutcome::Timeout))
        } else if decision == UserDecision::Rejected {
            Some((CoreError::Rejected, ToolOutcome::Rejected))
        } else {
            None
        };
        if let Some((error, outcome)) = refusal {
            actor.complete_action(run, &pending.call_id, pending.step_id.as_ref(), outcome)?;
            return Err(error);
        }
        Ok(AuthorizedEditorTool {
            run: run.clone(),
            action,
            lease: pending.lease,
            deadline: pending.deadline,
            step_id: pending.step_id,
        })
    }
}
