//! Editor orchestration borrows the committed model invocation. Only native
//! issuance/verified settlement can establish effects; callback prose cannot.
use super::*;
use crate::{
    application::ToolOutcome,
    edit::{prepare::ParentPolicy, types::EditorSourceId},
    ipc::pending::{PendingFailure, PendingOutcome},
};
use tokio::{sync::oneshot, time::Instant};

pub(super) struct NativeEdit {
    call: AgentTool,
    origin: EditorSourceId,
    reverse: RpcId,
    receiver: oneshot::Receiver<PendingOutcome>,
    deadline: Instant,
    closed: bool,
    fallback: ToolOutcome,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    scope: RunScope,
    call_id: ToolCallId,
    origin_id: EditorSourceId,
    finished: bool,
    failure: Option<Failure>,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Failure {
    Failed,
    Rejected,
    Cancelled,
    Timeout,
}
impl Failure {
    fn outcome(self) -> ToolOutcome {
        match self {
            Self::Failed => ToolOutcome::Failed,
            Self::Rejected => ToolOutcome::Rejected,
            Self::Cancelled => ToolOutcome::Cancelled,
            Self::Timeout => ToolOutcome::Timeout,
        }
    }
}
impl NativeEdit {
    pub fn start(
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        call: AgentTool,
        policy: ParentPolicy,
        messages: &mut Vec<Value>,
    ) -> Result<Self, Box<(CoreError, AgentTool)>> {
        Self::start_selected(host, ctx, forward, call, policy, None, messages)
    }
    pub fn start_selected(
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        call: AgentTool,
        policy: ParentPolicy,
        selection: Option<crate::sensors::symbols::SymbolEditSelection>,
        messages: &mut Vec<Value>,
    ) -> Result<Self, Box<(CoreError, AgentTool)>> {
        let result = (|| {
            let origin = EditorSourceId::new();
            let reverse = RpcId::String(format!(
                "r:edit:{}:{}",
                host.request_scope()?.as_str(),
                call.id().as_str()
            ));
            let deadline = call.run().deadline().cap(
                Instant::now()
                    .checked_add(timeouts::APPROVAL)
                    .ok_or(CoreError::ArithmeticOverflow)?,
            );
            let message = editor::request(
                host,
                forward,
                &reverse,
                &call,
                "editor/run_edit",
                json!({"origin_id":origin,"edit_policy":policy,"symbol_selection":selection}),
            )?;
            let receiver = ctx
                .pending
                .register(reverse.clone(), host.request_scope()?, deadline)
                .map_err(|_| CoreError::Limit)?;
            let scope = ReadScope {
                application_id: call.run().scope().application_id().clone(),
                session_id: call.run().scope().session_id().clone(),
            };
            if let Err(error) = host.actor_mut(&scope).and_then(|actor| {
                actor.edits.register_parent(
                    origin.clone(),
                    call.native_edit_call()?,
                    policy,
                    selection,
                )
            }) {
                ctx.pending.cancel(&reverse, &host.request_scope()?);
                return Err(error);
            }
            Ok((origin, reverse, receiver, deadline, message))
        })();
        match result {
            Ok((origin, reverse, receiver, deadline, message)) => {
                messages.push(message);
                Ok(Self {
                    call,
                    origin,
                    reverse,
                    receiver,
                    deadline,
                    closed: false,
                    fallback: ToolOutcome::Failed,
                })
            }
            Err(error) => Err(Box::new((error, call))),
        }
    }
    pub fn into_call(self) -> AgentTool {
        self.call
    }
    pub fn poll(
        &mut self,
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        scope: &ReadScope,
        terminal: Option<&CoreError>,
        messages: &mut Vec<Value>,
    ) -> Result<Option<(ToolOutcome, String)>, CoreError> {
        if !self.closed {
            let expired = Instant::now() >= self.deadline;
            let received = if expired || terminal.is_some() {
                Some(Err(
                    if expired || matches!(terminal, Some(CoreError::Deadline)) {
                        PendingFailure::Timeout
                    } else {
                        PendingFailure::Cancelled
                    },
                ))
            } else {
                match self.receiver.try_recv() {
                    Err(oneshot::error::TryRecvError::Empty) => None,
                    Err(oneshot::error::TryRecvError::Closed) => {
                        Some(Err(PendingFailure::Disconnected))
                    }
                    Ok(value) => Some(value),
                }
            };
            if let Some(received) = received {
                self.fallback = match received {
                    Ok(value) => serde_json::from_value::<Completion>(value)
                        .ok()
                        .filter(|done| {
                            done.finished
                                && done.scope == *self.call.run().scope()
                                && done.call_id == *self.call.id()
                                && done.origin_id == self.origin
                        })
                        .and_then(|done| done.failure)
                        .map_or(ToolOutcome::Failed, Failure::outcome),
                    Err(PendingFailure::Timeout) => ToolOutcome::Timeout,
                    Err(PendingFailure::Cancelled) => ToolOutcome::Cancelled,
                    Err(_) => ToolOutcome::Failed,
                };
                // Tombstone before notifying the peer: a delayed Begin or
                // Authorize cannot acquire fresh rights after observation ends.
                host.actor_mut(scope)?
                    .edits
                    .close_parent(&scope.session_id, &self.origin);
                ctx.pending.cancel(&self.reverse, &host.request_scope()?);
                let notice = json!({"jsonrpc":"2.0","method":"editor/cancel_edit","params":{
                    "request_id":forward.value(),"connection_epoch":host.request_scope()?.as_str(),
                    "scope":self.call.run().scope(),"call_id":self.call.id(),"origin_id":self.origin}});
                if notice.to_string().len() <= host.frame_limit().as_usize() {
                    messages.push(notice);
                }
                self.closed = true;
            }
        }
        let actor = host.actor_mut(scope)?;
        if !self.closed || actor.edits.parent_busy(&scope.session_id, &self.origin) {
            return Ok(None);
        }
        let observed = if let Some(step) = actor.edits.parent_step(&scope.session_id, &self.origin)
        {
            match actor.action_outcome(self.call.run(), self.call.id(), step)? {
                Some(outcome) => Some(outcome),
                None => return Ok(None),
            }
        } else {
            None
        };
        if let Some(result) = actor
            .edits
            .take_parent_result(&scope.session_id, &self.origin)
        {
            if observed != Some(result.outcome) {
                return Err(CoreError::InvalidToolOutput);
            }
            return Ok(Some((result.outcome, result.text)));
        }
        let outcome = observed.unwrap_or(self.fallback);
        Ok(Some((outcome, outcome.summary().to_owned())))
    }
}
