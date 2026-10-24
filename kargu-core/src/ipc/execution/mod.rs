//! Single-writer command admission, reverse approval and nonblocking completion.

pub(crate) mod input;
mod jobs;
mod reply;

use super::{
    pending::{PendingOutcome, PendingRequests},
    protocol::{self, Fault, RpcId},
};
use crate::{
    application::{
        RunHandle, RunPurpose,
        host::{Host, ReadScope},
    },
    constants::{
        limits,
        protocol::{error_codes as codes, methods},
    },
    domain::{JobId, RequestSequence, ToolCallId, ToolName},
    error::CoreError,
    process::{CleanupPolicy, JobStatus, ProcessSupervisor},
    security::{ApprovalRequest, ExecutionGate, ToolRegistry, UserDecision},
};
use futures_util::FutureExt;
use input::{ExecuteInput, Prepared};
use reply::Reply;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio::{sync::oneshot, task::JoinHandle};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecuteRequest {
    scope: ReadScope,
    arguments: ExecuteInput,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListingRequest {
    scope: ReadScope,
    arguments: crate::workspace::listing::ListFilesInput,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GrepRequest {
    scope: ReadScope,
    arguments: crate::workspace::grep::GrepInput,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GitStatusRequest {
    scope: ReadScope,
    arguments: crate::workspace::git::GitStatusInput,
}

enum Stage {
    Preparing(JoinHandle<Result<Prepared, CoreError>>),
    Review {
        run: Box<RunHandle>,
        request: Box<ApprovalRequest>,
        reverse: RpcId,
        receiver: oneshot::Receiver<PendingOutcome>,
    },
    Running {
        run: Box<RunHandle>,
        job: JobId,
        reply: Reply,
    },
}
struct Operation {
    purpose: RunPurpose,
    scope: ReadScope,
    stage: Option<Stage>,
    terminal: Option<CoreError>,
}
enum Progress {
    Pending(Stage),
    Done(Result<Value, CoreError>),
}

pub(super) struct Commands {
    operations: HashMap<RpcId, Operation>,
    gate: ExecutionGate,
    registry: ToolRegistry,
    supervisor: ProcessSupervisor,
    sequence: RequestSequence,
    jobs: jobs::Jobs,
}
impl Commands {
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.operations
            .values()
            .any(|operation| &operation.scope.application_id == id)
            || self.jobs.owns_application(id)
    }
    pub fn new() -> Result<Self, CoreError> {
        let mut registry = ToolRegistry::default();
        registry.register_process(ToolName::try_from("bash".to_owned())?, vec![])?;
        registry.register_listing()?;
        registry.register_grep()?;
        registry.register_git_status()?;
        Ok(Self {
            operations: HashMap::new(),
            gate: ExecutionGate::default(),
            registry,
            supervisor: ProcessSupervisor::new(CleanupPolicy::default())?,
            sequence: RequestSequence::ZERO,
            jobs: jobs::Jobs::default(),
        })
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.operations.contains_key(id) || self.jobs.contains_request(id)
    }
    pub fn is_empty(&self) -> bool {
        self.operations.is_empty() && self.jobs.is_idle()
    }
    pub fn start(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        self.start_kind(host, id, params, RunPurpose::AgentTurn)
    }
    pub fn start_job(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        self.start_kind(host, id, params, RunPurpose::ProcessJob)
    }
    fn start_kind(
        &mut self,
        host: &Host,
        id: RpcId,
        params: Value,
        purpose: RunPurpose,
    ) -> Result<(), Fault> {
        let request: ExecuteRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        self.admit(host, id, request.scope, purpose, move || {
            request.arguments.prepare(purpose)
        })
    }
    pub fn start_listing(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        let request: ListingRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        self.admit(host, id, request.scope, RunPurpose::AgentTurn, move || {
            let (command, settings) = request.arguments.prepare()?;
            Ok(Prepared {
                command,
                settings,
                tool: ToolName::try_from("list_files".to_owned())?,
                reply: Reply::Command,
            })
        })
    }
    pub fn start_grep(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        let request: GrepRequest = serde_json::from_value(params).map_err(|_| Fault::params())?;
        self.admit(host, id, request.scope, RunPurpose::AgentTurn, move || {
            let (command, settings, report) = request.arguments.prepare()?;
            Ok(Prepared {
                command,
                settings,
                tool: ToolName::try_from("workspace_grep".to_owned())?,
                reply: Reply::Grep(report),
            })
        })
    }
    pub fn start_git_status(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        let request: GitStatusRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        self.admit(host, id, request.scope, RunPurpose::AgentTurn, move || {
            let (command, settings, report) = request.arguments.prepare()?;
            Ok(Prepared {
                command,
                settings,
                tool: ToolName::try_from("git_status".to_owned())?,
                reply: Reply::GitStatus(report),
            })
        })
    }
    fn admit(
        &mut self,
        host: &Host,
        id: RpcId,
        scope: ReadScope,
        purpose: RunPurpose,
        prepare: impl FnOnce() -> Result<Prepared, CoreError> + Send + 'static,
    ) -> Result<(), Fault> {
        if !host.owns_read_scope(&scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        if self.operations.len() >= limits::HOST_PROCESSES || self.contains(&id) {
            return Err(fault(CoreError::Limit));
        }
        // Reserve application ownership before off-mailbox filesystem preparation.
        if self.operations.values().any(|op| {
            op.scope.application_id == scope.application_id
                && op.purpose == RunPurpose::AgentTurn
                && purpose == RunPurpose::AgentTurn
        }) {
            return Err(fault(CoreError::Busy));
        }
        if purpose == RunPurpose::ProcessJob {
            self.jobs.admission(&scope.application_id).map_err(fault)?;
            if self
                .operations
                .values()
                .filter(|op| {
                    op.scope.application_id == scope.application_id
                        && op.purpose == RunPurpose::ProcessJob
                })
                .count()
                >= limits::APPLICATION_JOBS
            {
                return Err(fault(CoreError::Limit));
            }
        }
        self.operations.insert(
            id,
            Operation {
                purpose,
                scope,
                stage: Some(Stage::Preparing(tokio::task::spawn_blocking(prepare))),
                terminal: None,
            },
        );
        Ok(())
    }
    pub fn cancel(&mut self, id: &RpcId) {
        self.jobs.cancel_request(id);
        if let Some(op) = self.operations.get_mut(id) {
            op.terminal = Some(CoreError::Cancelled);
        }
    }
    pub fn cancel_all(&mut self) {
        self.jobs.cancel_all();
        for op in self.operations.values_mut() {
            op.terminal = Some(CoreError::Cancelled);
        }
    }
    pub fn tick(
        &mut self,
        host: &mut Host,
        pending: &mut PendingRequests,
    ) -> Result<Vec<Value>, CoreError> {
        let ids: Vec<_> = self.operations.keys().cloned().collect();
        let mut messages = self.jobs.tick(host, &mut self.supervisor)?;
        for id in ids {
            let mut op = self
                .operations
                .remove(&id)
                .ok_or(CoreError::CleanupFailed)?;
            if !host.owns_read_scope(&op.scope) && op.terminal.is_none() {
                op.terminal = Some(CoreError::StaleOwner);
            }
            let stage = op.stage.take().ok_or(CoreError::CleanupFailed)?;
            let progress = self.advance(host, pending, &id, &mut op, stage, &mut messages)?;
            match progress {
                Progress::Pending(stage) => {
                    op.stage = Some(stage);
                    self.operations.insert(id, op);
                }
                Progress::Done(result) => {
                    let result = op.terminal.map_or(result, Err);
                    messages.push(match result {
                        Ok(value) => protocol::success(&id, value),
                        Err(error) => fault(error).response(Some(&id)),
                    });
                }
            }
        }
        Ok(messages)
    }
    fn advance(
        &mut self,
        host: &mut Host,
        pending: &mut PendingRequests,
        id: &RpcId,
        op: &mut Operation,
        stage: Stage,
        messages: &mut Vec<Value>,
    ) -> Result<Progress, CoreError> {
        match stage {
            Stage::Preparing(mut task) => {
                let Some(result) = (&mut task).now_or_never() else {
                    return Ok(Progress::Pending(Stage::Preparing(task)));
                };
                let prepared = match result.map_err(|_| CoreError::CleanupFailed)? {
                    Ok(prepared) if op.terminal.is_none() => prepared,
                    Ok(_) => return Ok(Progress::Done(Err(CoreError::Cancelled))),
                    Err(error) => return Ok(Progress::Done(Err(error))),
                };
                self.prepare(host, pending, id, op, prepared, messages)
            }
            Stage::Review {
                run,
                request,
                reverse,
                mut receiver,
            } => {
                let actor = host.actor_mut(&op.scope)?;
                if op.terminal.is_none()
                    && let Err(error) = run.check_live()
                {
                    op.terminal = Some(error);
                }
                if op.terminal.is_some() || run.check_live().is_err() {
                    actor.cancel(&run)?;
                    self.gate.dismiss_run(actor, &run)?;
                    pending.cancel(&reverse, &host.request_scope()?);
                    messages.push(json!({"jsonrpc":"2.0","method":methods::CANCEL,"params":{"request_id":reverse.value(),"scope":host.request_scope()?.as_str()}}));
                    host.actor_mut(&op.scope)?.finish(&run)?;
                    return Ok(Progress::Done(Err(CoreError::Cancelled)));
                }
                let decision = match receiver.try_recv() {
                    Err(oneshot::error::TryRecvError::Empty) => {
                        return Ok(Progress::Pending(Stage::Review {
                            run,
                            request,
                            reverse,
                            receiver,
                        }));
                    }
                    Ok(Ok(value)) if value == json!({"approved":true}) => UserDecision::Approved,
                    _ => UserDecision::Rejected,
                };
                self.launch(host, &op.scope, run, request, decision, Reply::Command)
            }
            Stage::Running { run, job, reply } => {
                if op.terminal.is_some() {
                    host.actor_mut(&op.scope)?.cancel(&run)?;
                }
                self.collect(host, &op.scope, run, job, reply)
            }
        }
    }
    fn prepare(
        &mut self,
        host: &mut Host,
        pending: &mut PendingRequests,
        id: &RpcId,
        operation: &Operation,
        prepared: Prepared,
        messages: &mut Vec<Value>,
    ) -> Result<Progress, CoreError> {
        let scope = &operation.scope;
        let actor = host.actor_mut(scope)?;
        let admitted = match operation.purpose {
            RunPurpose::AgentTurn => actor.admit(&scope.session_id, prepared.settings),
            RunPurpose::ProcessJob => actor.admit_job(&scope.session_id, prepared.settings),
        };
        let run = match admitted {
            Ok(run) => Box::new(run),
            Err(error) => return Ok(Progress::Done(Err(error))),
        };
        let request = match self.gate.prepare(
            actor,
            &run,
            &self.registry,
            &prepared.tool,
            ToolCallId::new(),
            prepared.command,
        ) {
            Ok(request) => request,
            Err(error) => {
                actor.cancel(&run)?;
                actor.finish(&run)?;
                return Ok(Progress::Done(Err(error)));
            }
        };
        if matches!(
            prepared.tool.as_str(),
            "list_files" | "workspace_grep" | "git_status"
        ) {
            return self.launch(
                host,
                scope,
                run,
                Box::new(request),
                UserDecision::Approved,
                prepared.reply,
            );
        }
        self.sequence = self.sequence.next()?;
        let reverse = RpcId::String(format!(
            "r:{}:{}",
            host.request_scope()?.as_str(),
            self.sequence.as_u64()
        ));
        let message = json!({"jsonrpc":"2.0","id":reverse.value(),"method":methods::REQUEST_APPROVAL,
            "params":{"request_id":id.value(),"approval_id":request.id(),"scope":request.scope(),"program":request.program(),"invocation":request.invocation(),
            "retention":request.retention(),"output_bytes":request.output_limit(),"timeout_ms":request.execution_timeout().duration().map(|duration| duration.as_millis()),"stderr":request.stderr(),
            "idle_timeout_ms":request.idle_timeout().duration().map(|duration| duration.as_millis()),
            "stdout_records":request.stdout_records(),"success_codes":request.success_codes(),
            "stop_on_bytes":request.stop_on_bytes(),
            "arguments":request.arguments().iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>(),"cwd":request.working_directory(),
            "environment":request.environment().entries().map(|(k,v)| (k.to_string_lossy().into_owned(),v.to_string_lossy().into_owned())).collect::<std::collections::BTreeMap<_,_>>()}});
        if message.to_string().len() > host.frame_limit().as_usize() {
            return self.reject_review(host, scope, &run);
        }
        let receiver =
            match pending.register(reverse.clone(), host.request_scope()?, request.deadline()) {
                Ok(receiver) => receiver,
                Err(_) => return self.reject_review(host, scope, &run),
            };
        messages.push(message);
        Ok(Progress::Pending(Stage::Review {
            run,
            request: Box::new(request),
            reverse,
            receiver,
        }))
    }
    fn reject_review(
        &mut self,
        host: &mut Host,
        scope: &ReadScope,
        run: &RunHandle,
    ) -> Result<Progress, CoreError> {
        let actor = host.actor_mut(scope)?;
        actor.cancel(run)?;
        self.gate.dismiss_run(actor, run)?;
        actor.finish(run)?;
        Ok(Progress::Done(Err(CoreError::Limit)))
    }
    fn launch(
        &mut self,
        host: &mut Host,
        scope: &ReadScope,
        run: Box<RunHandle>,
        request: Box<ApprovalRequest>,
        decision: UserDecision,
        reply: Reply,
    ) -> Result<Progress, CoreError> {
        let actor = host.actor_mut(scope)?;
        let grant = match self.gate.decide(actor, &run, &request, decision) {
            Ok(grant) => grant,
            Err(error) => {
                actor.cancel(&run)?;
                self.gate.dismiss_run(actor, &run)?;
                actor.finish(&run)?;
                return Ok(Progress::Done(Err(error)));
            }
        };
        match self.supervisor.start(actor, grant) {
            Ok(job) => {
                if run.scope().purpose() == RunPurpose::ProcessJob {
                    return self
                        .jobs
                        .register(scope.clone(), run, job, &self.supervisor)
                        .map(|value| Progress::Done(Ok(value)));
                }
                if let Err(error) = self.supervisor.close_input(&run, &job) {
                    actor.cancel(&run)?;
                    return Err(error);
                }
                Ok(Progress::Pending(Stage::Running { run, job, reply }))
            }
            Err(error) => {
                actor.cancel(&run)?;
                actor.finish(&run)?;
                Ok(Progress::Done(Err(error)))
            }
        }
    }
    fn collect(
        &mut self,
        host: &mut Host,
        scope: &ReadScope,
        run: Box<RunHandle>,
        job: JobId,
        reply: Reply,
    ) -> Result<Progress, CoreError> {
        if self.supervisor.status(&run, &job)? != JobStatus::CompletionReady {
            return Ok(Progress::Pending(Stage::Running { run, job, reply }));
        }
        let limit = reply.capture_limit()?;
        let Some(output) = self.supervisor.capture(&run, &job, limit)? else {
            return Ok(Progress::Pending(Stage::Running { run, job, reply }));
        };
        let Some(mut completion) = self.supervisor.try_wait(&run, &job)? else {
            return Ok(Progress::Pending(Stage::Running { run, job, reply }));
        };
        let result = reply.render(completion.result(), &output);
        if result.is_err() {
            completion.reject_output();
        }
        completion.deliver(host.actor_mut(scope)?)?;
        self.supervisor.forget(&run, &job)?;
        host.actor_mut(scope)?.finish(&run)?;
        Ok(Progress::Done(result))
    }
    pub fn job_rpc(
        &mut self,
        host: &Host,
        id: RpcId,
        method: &str,
        params: Value,
    ) -> Result<Option<Value>, Fault> {
        self.jobs
            .rpc(host, &mut self.supervisor, id, method, params)
    }
}

pub(super) fn fault(error: CoreError) -> Fault {
    let (code, message, status) = match error {
        CoreError::InvalidToolOutput => (
            codes::INVALID_STATE,
            "Invalid or incomplete structured tool output",
            "invalid_output",
        ),
        CoreError::InputOutcomeUnknown => (
            codes::OUTCOME_UNKNOWN,
            "Stdin delivery is unconfirmed; do not retry automatically",
            "outcome_unknown",
        ),
        CoreError::InvalidValue { .. } => (
            codes::INVALID_PARAMS,
            "Invalid command arguments",
            "invalid_params",
        ),
        CoreError::Busy => (
            codes::RESOURCE_LIMIT,
            "Application command is active or draining",
            "busy",
        ),
        CoreError::StaleOwner => (
            codes::STALE_OWNER,
            "Command owner is no longer live",
            "stale_owner",
        ),
        CoreError::Cancelled => (codes::CANCELLED, "Command cancelled", "cancelled"),
        CoreError::Deadline | CoreError::ApprovalExpired => {
            (codes::TIMEOUT, "Command deadline exceeded", "timeout")
        }
        CoreError::Rejected | CoreError::ApprovalUnavailable => (
            codes::REJECTED,
            "Command was not approved or permitted",
            "rejected",
        ),
        CoreError::WorkspaceChanged => (
            codes::WORKSPACE_CHANGED,
            "Command workspace or executable changed",
            "workspace_changed",
        ),
        CoreError::Unavailable => (
            codes::METHOD_NOT_FOUND,
            "Required executable or command service unavailable",
            "unavailable",
        ),
        CoreError::Io(_) => (
            codes::IO,
            "Command filesystem or process operation failed",
            "io_error",
        ),
        _ => (
            codes::RESOURCE_LIMIT,
            "Command resource or cleanup failure",
            "resource_limit",
        ),
    };
    Fault {
        code,
        message,
        status,
    }
}
