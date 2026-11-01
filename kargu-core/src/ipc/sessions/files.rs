//! Live read-file observations are captured before the shared read worker and
//! rechecked after its actual join. No error silently chooses a disk source.

use super::*;
use crate::{
    application::ToolOutcome,
    ipc::{
        pending::{PendingFailure, PendingOutcome},
        read_tools::PreparedReadCall,
    },
    sensors::diagnostics::DocumentStamp,
    workspace::file::EditorSnapshot,
};
use serde::Serialize;
use tokio::{sync::oneshot, time::Instant};

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum ObservationStamp {
    Disk {},
    Editor {
        document: DocumentStamp,
        dirty: bool,
    },
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum Observation {
    Disk {},
    Editor {
        document: DocumentStamp,
        dirty: bool,
        source: EditorSnapshot,
    },
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Captured {
    scope: RunScope,
    call_id: ToolCallId,
    observation: Observation,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Checked {
    scope: RunScope,
    call_id: ToolCallId,
    current: bool,
}

pub(super) struct FileCapture {
    call: AgentTool,
    prepared: PreparedReadCall,
    id: RpcId,
    receiver: oneshot::Receiver<PendingOutcome>,
}
impl FileCapture {
    pub fn start(
        host: &Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        call: AgentTool,
        messages: &mut Vec<Value>,
    ) -> Result<Self, Box<(CoreError, AgentTool)>> {
        let result = (|| {
            let prepared = PreparedReadCall::capture_file(&call)?;
            let id = id(host, &call, "capture")?;
            let message = editor::request(
                host,
                forward,
                &id,
                &call,
                "editor/read_file_snapshot",
                json!({"capture":prepared.capture_request()?}),
            )?;
            let receiver = ctx
                .pending
                .register(id.clone(), host.request_scope()?, deadline(&call)?)
                .map_err(|_| CoreError::Limit)?;
            Ok((prepared, id, receiver, message))
        })();
        match result {
            Ok((prepared, id, receiver, message)) => {
                messages.push(message);
                Ok(Self {
                    call,
                    prepared,
                    id,
                    receiver,
                })
            }
            Err(error) => Err(Box::new((error, call))),
        }
    }
    pub fn poll(&mut self) -> Result<Option<Observation>, CoreError> {
        let value = match self.receiver.try_recv() {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => return Err(pending_error(error)),
            Err(oneshot::error::TryRecvError::Closed) => return Err(CoreError::StaleOwner),
            Err(oneshot::error::TryRecvError::Empty) => return Ok(None),
        };
        let captured: Captured =
            serde_json::from_value(value).map_err(|_| CoreError::InvalidToolOutput)?;
        if captured.scope != *self.call.run().scope() || captured.call_id != *self.call.id() {
            return Err(CoreError::StaleOwner);
        }
        if let Observation::Editor { document, .. } = &captured.observation {
            let request = self.prepared.capture_request()?;
            let path = request
                .get("path")
                .and_then(Value::as_str)
                .ok_or(CoreError::InvalidToolOutput)?;
            if document.path != crate::edit::types::EditPath::try_from(path.to_owned())? {
                return Err(CoreError::StaleOwner);
            }
        }
        Ok(Some(captured.observation))
    }
    pub fn cancel(&self, host: &Host, ctx: &mut SessionContext<'_>) -> Result<(), CoreError> {
        ctx.pending.cancel(&self.id, &host.request_scope()?);
        Ok(())
    }
    pub fn into_call(self) -> AgentTool {
        self.call
    }
    pub fn prepare(
        self,
        observation: Observation,
    ) -> Result<(AgentTool, PreparedReadCall, ObservationStamp), Box<(CoreError, AgentTool)>> {
        let (plan, stamp) = match observation {
            Observation::Disk {} => (Ok(self.prepared), ObservationStamp::Disk {}),
            Observation::Editor {
                document,
                dirty,
                source,
            } => (
                self.prepared.with_editor_snapshot(source),
                ObservationStamp::Editor { document, dirty },
            ),
        };
        match plan {
            Ok(plan) => Ok((self.call, plan, stamp)),
            Err(error) => Err(Box::new((error, self.call))),
        }
    }
}

pub(super) struct FileValidation {
    delivery: ReadDelivery,
    id: RpcId,
    receiver: oneshot::Receiver<PendingOutcome>,
}
impl FileValidation {
    pub fn start(
        host: &Host,
        ctx: &mut SessionContext<'_>,
        forward: &RpcId,
        delivery: ReadDelivery,
        stamp: ObservationStamp,
        messages: &mut Vec<Value>,
    ) -> Result<Self, Box<(CoreError, ReadDelivery)>> {
        let result = (|| {
            let id = id(host, &delivery.call, "validate")?;
            let message = editor::request(
                host,
                forward,
                &id,
                &delivery.call,
                "editor/validate_file_snapshot",
                json!({"observation":stamp}),
            )?;
            let receiver = ctx
                .pending
                .register(id.clone(), host.request_scope()?, deadline(&delivery.call)?)
                .map_err(|_| CoreError::Limit)?;
            Ok((id, receiver, message))
        })();
        match result {
            Ok((id, receiver, message)) => {
                messages.push(message);
                Ok(Self {
                    delivery,
                    id,
                    receiver,
                })
            }
            Err(error) => Err(Box::new((error, delivery))),
        }
    }
    pub fn poll(&mut self) -> Option<Result<bool, CoreError>> {
        match self.receiver.try_recv() {
            Ok(Ok(value)) => Some(
                serde_json::from_value::<Checked>(value)
                    .map_err(|_| CoreError::InvalidToolOutput)
                    .and_then(|value| {
                        if value.scope == *self.delivery.call.run().scope()
                            && value.call_id == *self.delivery.call.id()
                        {
                            Ok(value.current)
                        } else {
                            Err(CoreError::StaleOwner)
                        }
                    }),
            ),
            Ok(Err(error)) => Some(Err(pending_error(error))),
            Err(oneshot::error::TryRecvError::Closed) => Some(Err(CoreError::StaleOwner)),
            Err(oneshot::error::TryRecvError::Empty) => None,
        }
    }
    pub fn cancel(&self, host: &Host, ctx: &mut SessionContext<'_>) -> Result<(), CoreError> {
        ctx.pending.cancel(&self.id, &host.request_scope()?);
        Ok(())
    }
    pub fn into_delivery(mut self, current: Result<bool, CoreError>) -> ReadDelivery {
        if !matches!(current, Ok(true)) {
            self.delivery.outcome = match current {
                Err(CoreError::Deadline) => ToolOutcome::Timeout,
                Err(CoreError::Cancelled) => ToolOutcome::Cancelled,
                _ => ToolOutcome::Failed,
            };
            self.delivery.text =
                "ERROR: live file source changed or could not be revalidated".to_owned();
        }
        self.delivery
    }
}

fn pending_error(error: PendingFailure) -> CoreError {
    match error {
        PendingFailure::Timeout => CoreError::Deadline,
        PendingFailure::Cancelled => CoreError::Cancelled,
        PendingFailure::Disconnected => CoreError::StaleOwner,
        PendingFailure::Remote(_) => CoreError::Unavailable,
    }
}

pub(super) fn release(
    host: &Host,
    forward: &RpcId,
    call: &AgentTool,
) -> Result<Option<Value>, CoreError> {
    let message = json!({"jsonrpc":"2.0","method":"editor/release_file_snapshot","params":{
        "request_id":forward.value(),"connection_epoch":host.request_scope()?.as_str(),
        "scope":call.run().scope(),"call_id":call.id()}});
    // This is smaller than a queued capture. If even the identity cannot fit,
    // capture was refused before queueing and no editor observation exists.
    Ok((message.to_string().len() <= host.frame_limit().as_usize()).then_some(message))
}
pub(super) fn failed(call: AgentTool, error: CoreError) -> ReadDelivery {
    let outcome = match error {
        CoreError::Cancelled => ToolOutcome::Cancelled,
        CoreError::Deadline => ToolOutcome::Timeout,
        CoreError::Rejected | CoreError::StaleOwner | CoreError::InvalidValue { .. } => {
            ToolOutcome::Rejected
        }
        _ => ToolOutcome::Failed,
    };
    ReadDelivery {
        id: RpcId::String(format!("s:read:refused:{}", call.id().as_str())),
        call,
        outcome,
        text: format!("{}: live file snapshot unavailable", outcome.summary()),
    }
}
fn id(host: &Host, call: &AgentTool, phase: &str) -> Result<RpcId, CoreError> {
    Ok(RpcId::String(format!(
        "r:file:{}:{}:{phase}",
        host.request_scope()?.as_str(),
        call.id().as_str()
    )))
}
fn deadline(call: &AgentTool) -> Result<Instant, CoreError> {
    Ok(call.run().deadline().cap(
        Instant::now()
            .checked_add(timeouts::WORKSPACE_READ)
            .ok_or(CoreError::ArithmeticOverflow)?,
    ))
}
