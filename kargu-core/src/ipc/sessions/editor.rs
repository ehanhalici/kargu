//! Scoped editor capture -> shared consent gate -> issued activity -> actual drain.
//! A reverse RPC timeout is an observation failure, never proof of quiescence.

use super::{SessionContext, *};
use crate::ipc::pending::PendingOutcome;
use crate::{
    application::ToolOutcome,
    domain::ToolSafetyLevel,
    ipc::pending::PendingFailure,
    security::{
        AuthorizedEditorTool, EditorPresenter, EditorResource, EditorToolAdmission,
        EditorToolApprovalRequest, IssuedEditorTool, PreparedEditorTool, UserDecision,
    },
    sensors::symbols::{
        SelectedSymbol, SymbolBody, SymbolEditSelection, SymbolLookup, SymbolName, SymbolSnapshot,
    },
};
use tokio::{sync::oneshot, time::Instant};

enum Phase {
    Capturing,
    Reviewing(EditorToolApprovalRequest),
    Issued(IssuedEditorTool, ReadStage),
    Settled,
}
enum ReadStage {
    Initial,
    Body(SelectedSymbol),
}
enum ReadProgress {
    Diagnostics {
        snapshot: Box<crate::sensors::diagnostics::DiagnosticSnapshot>,
        text: String,
    },
    Edit(SymbolEditSelection),
    Done(ToolOutcome, String),
    Body(SelectedSymbol),
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Observation {
    ProjectDiagnostics {
        snapshot: crate::sensors::diagnostics::ProjectDiagnostics,
    },
    Diagnostics {
        snapshot: crate::sensors::diagnostics::DiagnosticSnapshot,
    },
    Symbols {
        snapshot: SymbolSnapshot,
    },
    Body {
        snapshot: SymbolBody,
    },
    Unavailable {
        reason: SymbolFailure,
    },
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SymbolFailure {
    Unavailable,
    Stale,
    InvalidRange,
    Timeout,
    Cancelled,
    ResourceLimit,
}
impl SymbolFailure {
    fn result(self) -> ReadProgress {
        let (outcome, text) = match self {
            Self::Unavailable => (
                ToolOutcome::Failed,
                "ERROR: live symbol provider unavailable",
            ),
            Self::Stale => (
                ToolOutcome::Failed,
                "ERROR: symbol document or language provider changed",
            ),
            Self::InvalidRange => (
                ToolOutcome::Failed,
                "ERROR: symbol provider returned an invalid source range",
            ),
            Self::Timeout => (
                ToolOutcome::Timeout,
                "ERROR: symbol request deadline exceeded",
            ),
            Self::Cancelled => (ToolOutcome::Cancelled, "ERROR: symbol read cancelled"),
            Self::ResourceLimit => (
                ToolOutcome::Failed,
                "ERROR: symbol capture resource limit exceeded",
            ),
        };
        ReadProgress::Done(outcome, text.to_owned())
    }
}

pub(super) struct EditorCall {
    call: AgentTool,
    phase: Phase,
    id: RpcId,
    receiver: oneshot::Receiver<PendingOutcome>,
    deadline: Instant,
    cancel_sent: bool,
    step: Option<crate::domain::ToolStepId>,
    selection: Option<SymbolEditSelection>,
    verification: Option<crate::edit::prepare::VerificationTicket>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Captured {
    scope: RunScope,
    call_id: ToolCallId,
    resource: EditorResource,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Decision {
    scope: RunScope,
    call_id: ToolCallId,
    approved: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    scope: RunScope,
    call_id: ToolCallId,
    quiescent: bool,
    outcome: ToolOutcome,
    text: Option<String>,
    observation: Option<Observation>,
}

impl EditorCall {
    pub fn start(
        host: &Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        call: AgentTool,
        messages: &mut Vec<Value>,
    ) -> Result<Self, Box<(CoreError, AgentTool)>> {
        let result = (|| {
            call.run().settings().workspace().revalidate()?;
            let deadline = deadline(&call)?;
            let id = reverse_id(host, &call, "capture")?;
            let message = request(host, forward, &id, &call, "editor/prepare_tool", json!({}))?;
            let receiver = ctx
                .pending
                .register(id.clone(), host.request_scope()?, deadline)
                .map_err(|_| CoreError::Limit)?;
            Ok((deadline, id, receiver, message))
        })();
        match result {
            Ok((deadline, id, receiver, message)) => {
                messages.push(message);
                Ok(Self {
                    call,
                    phase: Phase::Capturing,
                    id,
                    receiver,
                    deadline,
                    cancel_sent: false,
                    step: None,
                    selection: None,
                    verification: None,
                })
            }
            Err(error) => Err(Box::new((error, call))),
        }
    }

    pub fn take_selection(&mut self) -> Option<SymbolEditSelection> {
        self.selection.take()
    }

    pub fn into_call(self) -> AgentTool {
        self.call
    }

    /// Keep every resource-owning phase in its parent registry on fallible exits.
    pub fn poll(
        &mut self,
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        scope: &ReadScope,
        terminal: Option<&CoreError>,
        messages: &mut Vec<Value>,
    ) -> Result<Option<(ToolOutcome, String)>, CoreError> {
        let expired = Instant::now() >= self.deadline;
        if terminal.is_some() || expired {
            if matches!(self.phase, Phase::Issued(..)) {
                if !self.cancel_sent {
                    let message = json!({"jsonrpc":"2.0","method":"editor/cancel_tool",
                        "params":{"connection_epoch":host.request_scope()?.as_str(),
                        "request_id":self.id.value(),"scope":self.call.run().scope(),"call_id":self.call.id()}});
                    messages.push(message);
                    self.cancel_sent = true;
                }
            } else {
                let outcome = if expired || matches!(terminal, Some(CoreError::Deadline)) {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                };
                if let Phase::Reviewing(review) = &self.phase {
                    ctx.commands.editor_tool_gate().abandon_editor_tool(
                        host.actor_mut(scope)?,
                        self.call.run(),
                        review,
                        outcome,
                    )?;
                }
                ctx.pending.cancel(&self.id, &host.request_scope()?);
                release_symbols(host, forward, &self.call, messages)?;
                self.phase = Phase::Settled;
                return Ok(Some((outcome, outcome.summary().to_owned())));
            }
        }
        let received = match self.receiver.try_recv() {
            Ok(result) => result,
            Err(oneshot::error::TryRecvError::Empty) => return Ok(None),
            Err(oneshot::error::TryRecvError::Closed) => Err(PendingFailure::Disconnected),
        };
        match &self.phase {
            Phase::Capturing => {
                let captured: Captured = match received.and_then(|value| {
                    serde_json::from_value::<Captured>(value)
                        .map_err(|_| PendingFailure::Remote(Value::Null))
                }) {
                    Ok(value)
                        if value.scope == *self.call.run().scope()
                            && value.call_id == *self.call.id() =>
                    {
                        value
                    }
                    _ => {
                        release_symbols(host, forward, &self.call, messages)?;
                        return Ok(Some((
                            ToolOutcome::Failed,
                            "ERROR: editor resource capture unavailable".to_owned(),
                        )));
                    }
                };
                let (name, arguments) = editor_action(&self.call)?;
                let prepared = match PreparedEditorTool::prepare(
                    self.call.run(),
                    self.call.run().tool_registry(),
                    &name,
                    self.call.id().clone(),
                    arguments,
                    captured.resource,
                ) {
                    Ok(prepared) => prepared,
                    Err(_) => {
                        release_symbols(host, forward, &self.call, messages)?;
                        return Ok(Some((
                            ToolOutcome::Rejected,
                            ToolOutcome::Rejected.summary().to_owned(),
                        )));
                    }
                };
                if self.call.name().as_str() == "edit_by_lsp" {
                    self.step = Some(host.actor_mut(scope)?.register_step(
                        self.call.run(),
                        self.call.id(),
                        &name,
                    )?);
                }
                let admission = match ctx.commands.editor_tool_gate().prepare_editor_tool_action(
                    host.actor_mut(scope)?,
                    self.call.run(),
                    prepared,
                    EditorPresenter::Available,
                    self.step.clone(),
                ) {
                    Ok(admission) => admission,
                    Err(error) => return self.unissued(host, ctx, forward, scope, error, messages),
                };
                match admission {
                    EditorToolAdmission::Authorized(grant) => {
                        if let Err(error) = self.issue(host, ctx, forward, scope, grant, messages) {
                            return self.unissued(host, ctx, forward, scope, error, messages);
                        }
                    }
                    EditorToolAdmission::Review(review) => {
                        self.deadline = review.deadline();
                        self.phase = Phase::Reviewing(review);
                        let Phase::Reviewing(review) = &self.phase else {
                            return Err(CoreError::CleanupFailed);
                        };
                        let id = reverse_id(host, &self.call, "approval")?;
                        let action = ctx
                            .commands
                            .editor_tool_gate()
                            .editor_tool_action(self.call.run(), review)?;
                        let message = request(
                            host,
                            forward,
                            &id,
                            &self.call,
                            "editor/approve_tool",
                            json!({"resource":action.resource(),"approval_id":review.id(),"digest":review.digest(),"safety":action.safety()}),
                        )?;
                        let receiver = ctx
                            .pending
                            .register(id.clone(), host.request_scope()?, self.deadline)
                            .map_err(|_| CoreError::Limit)?;
                        self.id = id;
                        self.receiver = receiver;
                        messages.push(message);
                    }
                }
                Ok(None)
            }
            Phase::Reviewing(review) => {
                let decision: Option<Decision> = received
                    .ok()
                    .and_then(|value| serde_json::from_value(value).ok());
                let approved = decision.is_some_and(|decision| {
                    decision.scope == *self.call.run().scope()
                        && decision.call_id == *self.call.id()
                        && decision.approved
                });
                let grant = ctx.commands.editor_tool_gate().decide_editor_tool(
                    host.actor_mut(scope)?,
                    self.call.run(),
                    review,
                    if approved {
                        UserDecision::Approved
                    } else {
                        UserDecision::Rejected
                    },
                );
                match grant {
                    Ok(grant) => {
                        self.phase = Phase::Settled;
                        if let Err(error) = self.issue(host, ctx, forward, scope, grant, messages) {
                            return self.unissued(host, ctx, forward, scope, error, messages);
                        }
                        Ok(None)
                    }
                    Err(CoreError::Rejected) => {
                        self.phase = Phase::Settled;
                        Ok(Some((
                            ToolOutcome::Rejected,
                            ToolOutcome::Rejected.summary().to_owned(),
                        )))
                    }
                    Err(CoreError::ApprovalExpired) => {
                        self.phase = Phase::Settled;
                        Ok(Some((
                            ToolOutcome::Timeout,
                            ToolOutcome::Timeout.summary().to_owned(),
                        )))
                    }
                    Err(error) => Err(error),
                }
            }
            Phase::Issued(grant, stage) => {
                let missing = if grant.action().safety() == ToolSafetyLevel::SafeReadOnly {
                    ToolOutcome::Failed
                } else {
                    ToolOutcome::OutcomeUnknown
                };
                let revoked_read = matches!(
                    self.call.name().as_str(),
                    "read_file_symbols" | "read_symbol" | "edit_by_lsp" | "lsp_diagnostics"
                ) && (expired || terminal.is_some());
                let completion: Option<Completion> = if revoked_read {
                    None
                } else {
                    received
                        .ok()
                        .and_then(|value| serde_json::from_value(value).ok())
                };
                let completion = completion.filter(|value| {
                    value.quiescent
                        && value.scope == *self.call.run().scope()
                        && value.call_id == *self.call.id()
                });
                let progress = if revoked_read {
                    let outcome = if expired || matches!(terminal, Some(CoreError::Deadline)) {
                        ToolOutcome::Timeout
                    } else {
                        ToolOutcome::Cancelled
                    };
                    ReadProgress::Done(outcome, outcome.summary().to_owned())
                } else {
                    match completion {
                        Some(completion) => {
                            read_result(&self.call, grant.action().resource(), stage, completion)
                                .unwrap_or_else(|_| {
                                    ReadProgress::Done(
                                        ToolOutcome::Failed,
                                        "ERROR: invalid or stale typed editor observation"
                                            .to_owned(),
                                    )
                                })
                        }
                        None => ReadProgress::Done(missing, missing.summary().to_owned()),
                    }
                };
                let mut diagnostic = None;
                let result = match progress {
                    ReadProgress::Diagnostics { snapshot, text } => {
                        let outcome = if snapshot.freshness()
                            == crate::sensors::diagnostics::Freshness::Fresh
                        {
                            ToolOutcome::Ok
                        } else {
                            ToolOutcome::Failed
                        };
                        diagnostic = Some(snapshot);
                        (outcome, text)
                    }
                    ReadProgress::Done(outcome, text) => (outcome, text),
                    ReadProgress::Edit(selection) => {
                        self.selection = Some(selection);
                        (ToolOutcome::Ok, String::new())
                    }
                    ReadProgress::Body(selected) => {
                        if self.cancel_sent || terminal.is_some() || Instant::now() >= self.deadline
                        {
                            let outcome = if Instant::now() >= self.deadline
                                || matches!(terminal, Some(CoreError::Deadline))
                            {
                                ToolOutcome::Timeout
                            } else {
                                ToolOutcome::Cancelled
                            };
                            (outcome, outcome.summary().to_owned())
                        } else {
                            let next = (|| {
                                let id = reverse_id(host, &self.call, "symbol-body")?;
                                let message = request(
                                    host,
                                    forward,
                                    &id,
                                    &self.call,
                                    "editor/read_symbol_range",
                                    json!({"resource":grant.action().resource(),"range":selected.range()}),
                                )?;
                                let receiver = ctx
                                    .pending
                                    .register_effect(
                                        id.clone(),
                                        host.request_scope()?,
                                        self.deadline,
                                        self.call.run().scope().clone(),
                                        self.call.id().clone(),
                                    )
                                    .map_err(|_| CoreError::Limit)?;
                                Ok::<_, CoreError>((id, receiver, message))
                            })();
                            match next {
                                Ok((id, receiver, message)) => {
                                    let Phase::Issued(grant, _) =
                                        std::mem::replace(&mut self.phase, Phase::Settled)
                                    else {
                                        return Err(CoreError::CleanupFailed);
                                    };
                                    self.phase = Phase::Issued(grant, ReadStage::Body(selected));
                                    self.id = id;
                                    self.receiver = receiver;
                                    messages.push(message);
                                    return Ok(None);
                                }
                                Err(_) => (
                                    ToolOutcome::Failed,
                                    "ERROR: symbol body capture could not be admitted".to_owned(),
                                ),
                            }
                        }
                    }
                };
                let result = if result.0 == ToolOutcome::Cancelled
                    && (expired || matches!(terminal, Some(CoreError::Deadline)))
                {
                    (
                        ToolOutcome::Timeout,
                        ToolOutcome::Timeout.summary().to_owned(),
                    )
                } else {
                    result
                };
                // Complete facts while the issuance lease is still held; actual
                // history commit follows in the same actor turn via AgentTool.
                host.actor_mut(scope)?.complete_action(
                    self.call.run(),
                    self.call.id(),
                    self.step.as_ref(),
                    result.0,
                )?;
                if !self.cancel_sent
                    && Instant::now() < self.deadline
                    && self.call.run().check_live().is_ok()
                    && let (Some(ticket), Some(snapshot)) = (self.verification.take(), diagnostic)
                {
                    // The read action completed under its native issuance lease.
                    // Only this captured publication can consume the evidence.
                    // A refused metadata settlement keeps the debt. The read
                    // itself remains valid and must not complete its action twice.
                    let _settled = host
                        .actor_mut(scope)?
                        .edits
                        .settle_verification(&scope.session_id, ticket, &snapshot)
                        .unwrap_or(false);
                }
                release_symbols(host, forward, &self.call, messages)?;
                self.phase = Phase::Settled;
                Ok(Some(result))
            }
            Phase::Settled => Err(CoreError::AlreadyCompleted),
        }
    }

    fn issue(
        &mut self,
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        scope: &ReadScope,
        grant: AuthorizedEditorTool,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        if self.call.name().as_str() == "lsp_diagnostics"
            && let EditorResource::Document { document } = grant.action().resource()
        {
            self.verification = host.actor_mut(scope)?.edits.capture_verification(
                &scope.session_id,
                self.call.run().settings().workspace().path(),
                document,
            );
        }
        let id = reverse_id(host, &self.call, "issued")?;
        let deadline = self.deadline;
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(CoreError::Deadline)?;
        let timeout_ms = u64::try_from(remaining.as_millis())
            .map_err(|_| CoreError::ArithmeticOverflow)?
            .max(1);
        let message = request(
            host,
            forward,
            &id,
            &self.call,
            "editor/call_tool",
            json!({"resource":grant.action().resource(),"timeout_ms":timeout_ms}),
        )?;
        let receiver = ctx
            .pending
            .register_effect(
                id.clone(),
                host.request_scope()?,
                deadline,
                self.call.run().scope().clone(),
                self.call.id().clone(),
            )
            .map_err(|_| CoreError::Limit)?;
        let issued = match grant.issue(host.actor_mut(scope)?) {
            Ok(issued) => issued,
            Err(error) => {
                ctx.pending
                    .remove_unissued_effect(&id, &host.request_scope()?);
                return Err(error);
            }
        };
        self.id = id;
        self.receiver = receiver;
        self.deadline = deadline;
        self.phase = Phase::Issued(issued, ReadStage::Initial);
        messages.push(message);
        Ok(())
    }
    fn unissued(
        &mut self,
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        scope: &ReadScope,
        error: CoreError,
        messages: &mut Vec<Value>,
    ) -> Result<Option<(ToolOutcome, String)>, CoreError> {
        ctx.commands
            .editor_tool_gate()
            .dismiss_run(host.actor_mut(scope)?, self.call.run())?;
        release_symbols(host, forward, &self.call, messages)?;
        self.phase = Phase::Settled;
        let outcome = match error {
            CoreError::Cancelled => ToolOutcome::Cancelled,
            CoreError::Deadline | CoreError::ApprovalExpired => ToolOutcome::Timeout,
            CoreError::Rejected | CoreError::WorkspaceChanged | CoreError::StaleOwner => {
                ToolOutcome::Rejected
            }
            _ => ToolOutcome::Failed,
        };
        if let Some(step) = &self.step {
            host.actor_mut(scope)?
                .abandon_step(self.call.run(), self.call.id(), step, outcome)?;
        }
        Ok(Some((outcome, outcome.summary().to_owned())))
    }
}

fn release_symbols(
    host: &Host,
    forward: &RpcId,
    call: &AgentTool,
    messages: &mut Vec<Value>,
) -> Result<(), CoreError> {
    if matches!(
        call.name().as_str(),
        "read_file_symbols" | "read_symbol" | "edit_by_lsp"
    ) {
        let notice = json!({"jsonrpc":"2.0","method":"editor/release_symbol_snapshot","params":{
            "request_id":forward.value(),"connection_epoch":host.request_scope()?.as_str(),"scope":call.run().scope(),"call_id":call.id()}});
        if notice.to_string().len() <= host.frame_limit().as_usize() {
            messages.push(notice);
        }
    }
    Ok(())
}

fn read_result(
    call: &AgentTool,
    resource: &EditorResource,
    stage: &ReadStage,
    completion: Completion,
) -> Result<ReadProgress, CoreError> {
    if matches!(
        call.name().as_str(),
        "read_file_symbols" | "read_symbol" | "edit_by_lsp"
    ) && let Some(Observation::Unavailable { reason }) = &completion.observation
    {
        return Ok((*reason).result());
    }
    if completion.outcome != ToolOutcome::Ok {
        return Ok(ReadProgress::Done(
            completion.outcome,
            completion.outcome.summary().to_owned(),
        ));
    }
    if call.name().as_str() == "lsp_diagnostics" {
        call.run().settings().workspace().revalidate()?;
        let (freshness, text) = match (resource, completion.observation) {
            (
                EditorResource::Document { document },
                Some(Observation::Diagnostics { snapshot }),
            ) => {
                let (_, text) = snapshot.render_for(document)?;
                return Ok(ReadProgress::Diagnostics {
                    snapshot: Box::new(snapshot),
                    text,
                });
            }
            (EditorResource::Workspace {}, Some(Observation::ProjectDiagnostics { snapshot })) => {
                snapshot.render()?
            }
            _ => return Err(CoreError::InvalidToolOutput),
        };
        return Ok(ReadProgress::Done(
            if freshness == crate::sensors::diagnostics::Freshness::Fresh {
                ToolOutcome::Ok
            } else {
                ToolOutcome::Failed
            },
            text,
        ));
    }
    if matches!(
        call.name().as_str(),
        "read_file_symbols" | "read_symbol" | "edit_by_lsp"
    ) {
        call.run().settings().workspace().revalidate()?;
        let EditorResource::LanguageDocument { document, source } = resource else {
            return Err(CoreError::InvalidToolOutput);
        };
        return match (stage, completion.observation) {
            (ReadStage::Initial, Some(Observation::Symbols { snapshot }))
                if snapshot.fresh_for(document, source) =>
            {
                if call.name().as_str() == "read_file_symbols" {
                    Ok(ReadProgress::Done(
                        ToolOutcome::Ok,
                        snapshot.symbols().render_for(document),
                    ))
                } else {
                    let args: Value = serde_json::from_str(call.arguments().get())
                        .map_err(|_| CoreError::InvalidToolOutput)?;
                    let name = SymbolName::try_from(
                        args.get("symbol")
                            .and_then(Value::as_str)
                            .ok_or(CoreError::Rejected)?
                            .to_owned(),
                    )?;
                    match snapshot
                        .symbols()
                        .select(&name, args.get("kind").and_then(Value::as_str))?
                    {
                        SymbolLookup::Unique(selected) => {
                            if call.name().as_str() == "edit_by_lsp" {
                                Ok(ReadProgress::Edit(snapshot.select_edit(
                                    document,
                                    source,
                                    &name,
                                    args.get("kind").and_then(Value::as_str),
                                )?))
                            } else {
                                Ok(ReadProgress::Body(selected))
                            }
                        }
                        refused => Ok(ReadProgress::Done(
                            ToolOutcome::Failed,
                            refused.refusal_text(),
                        )),
                    }
                }
            }
            (ReadStage::Body(selected), Some(Observation::Body { snapshot }))
                if call.name().as_str() == "read_symbol" =>
            {
                Ok(ReadProgress::Done(
                    ToolOutcome::Ok,
                    snapshot.render(document, source, selected)?,
                ))
            }
            _ => Err(CoreError::InvalidToolOutput),
        };
    }
    Ok(ReadProgress::Done(
        completion.outcome,
        completion
            .text
            .unwrap_or_else(|| completion.outcome.summary().to_owned()),
    ))
}

fn deadline(call: &AgentTool) -> Result<Instant, CoreError> {
    Ok(call.run().deadline().cap(
        Instant::now()
            .checked_add(timeouts::EDIT_RECEIPT)
            .ok_or(CoreError::ArithmeticOverflow)?,
    ))
}
fn reverse_id(host: &Host, call: &AgentTool, phase: &str) -> Result<RpcId, CoreError> {
    Ok(RpcId::String(format!(
        "r:editor:{}:{}:{phase}",
        host.request_scope()?.as_str(),
        call.id().as_str()
    )))
}
pub(super) fn request(
    host: &Host,
    forward: &RpcId,
    id: &RpcId,
    call: &AgentTool,
    method: &'static str,
    extra: Value,
) -> Result<Value, CoreError> {
    let mut params = json!({"request_id":forward.value(),"connection_epoch":host.request_scope()?.as_str(),
        "scope":call.run().scope(),"root":call.run().settings().workspace().path(),
        "call_id":call.id(),"tool":call.name(),"arguments":call.arguments()});
    if call.name().as_str() == "edit_by_lsp"
        && matches!(method, "editor/prepare_tool" | "editor/call_tool")
    {
        let (name, arguments) = editor_action(call)?;
        let fields = params.as_object_mut().ok_or(CoreError::InvalidToolOutput)?;
        fields.insert("tool".into(), json!(name));
        fields.insert("arguments".into(), arguments);
        fields.insert("parent_tool".into(), json!("edit_by_lsp"));
    }
    params
        .as_object_mut()
        .ok_or(CoreError::InvalidToolOutput)?
        .extend(
            extra
                .as_object()
                .ok_or(CoreError::InvalidToolOutput)?
                .clone(),
        );
    let message = json!({"jsonrpc":"2.0","id":id.value(),"method":method,"params":params});
    if message.to_string().len() > host.frame_limit().as_usize() {
        return Err(CoreError::Limit);
    }
    Ok(message)
}

fn editor_action(call: &AgentTool) -> Result<(ToolName, Value), CoreError> {
    let args: Value =
        serde_json::from_str(call.arguments().get()).map_err(|_| CoreError::InvalidToolOutput)?;
    if call.name().as_str() == "edit_by_lsp" {
        Ok((
            ToolName::try_from("read_file_symbols".to_owned())?,
            json!({"file_path":args.get("file_path").ok_or(CoreError::Rejected)?}),
        ))
    } else {
        Ok((call.name().clone(), args))
    }
}
