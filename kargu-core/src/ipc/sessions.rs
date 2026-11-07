//! Actual native run ownership around the existing provider service. The domain
//! actor alone advances conversation state; this service retains IO handles and
//! consuming tickets until worker collection, including during teardown.

mod credential;
mod editor;
mod files;
mod native_edit;

use super::{
    api::{ApiRequests, ModelDelivery, RetryConfiguration},
    execution::{CommandDelivery, Commands},
    pending::PendingRequests,
    protocol::{self, Fault, RpcId},
    read_tools::{ReadDelivery, ReadTools},
};
use crate::{
    api::{ApiError, ChatConnection, HttpRequest},
    application::{
        ClaimIntent, Mode, PreparedRun, RequestedWorkspace, RunClaim, RunHandle, RunScope,
        agent::{
            AgentOptions, AgentPhase, AgentStop, AgentTool, ContinuationReason, ModelTurn,
            ModelTurnLimit, ToolAdmission,
        },
        budget::BudgetLimits,
        host::{Host, ReadScope},
    },
    constants::{limits, timeouts},
    domain::{
        BudgetId, ConfigRevision, ExecutionTimeout, PolicyRevision, ToolCallId, ToolCallLimit,
        ToolName,
    },
    error::CoreError,
    history::Message,
};
use futures_util::FutureExt;
use serde::Deserialize;
use serde_json::{Value, json, value::RawValue};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Duration};
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PromptRequest {
    scope: ReadScope,
    arguments: PromptInput,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PromptInput {
    root: PathBuf,
    mode: Mode,
    prompt: Option<Box<RawValue>>,
    tools_enabled: bool,
    #[serde(default)]
    editor_available: Vec<ToolName>,
    tool_limit: ToolCallLimit,
    turn_limit: ModelTurnLimit,
    timeout_ms: RunTimeout,
    config_revision: ConfigRevision,
    #[serde(default)]
    model_revision: crate::models::store::MetadataRevision,
    policy_revision: PolicyRevision,
    connection: ConnectionIntent,
    #[serde(default)]
    budget: BudgetLimits,
    retry: Option<RetryConfiguration>,
    #[serde(default)]
    edit_policy: crate::edit::prepare::ParentPolicy,
}
#[derive(Deserialize)]
#[serde(try_from = "Option<u64>")]
struct RunTimeout(ExecutionTimeout);
impl TryFrom<Option<u64>> for RunTimeout {
    type Error = CoreError;
    fn try_from(value: Option<u64>) -> Result<Self, CoreError> {
        if value.is_some_and(|ms| ms == 0 || ms > 86_400_000) {
            return Err(CoreError::InvalidValue {
                field: "RunTimeout",
            });
        }
        Ok(Self(ExecutionTimeout::try_from(
            value.map(Duration::from_millis),
        )?))
    }
}
#[derive(Deserialize)]
#[serde(try_from = "Box<RawValue>")]
struct ConnectionIntent(Zeroizing<String>);
impl ConnectionIntent {
    /// The editor's captured connection must name exactly the natively resolved
    /// provider, model and endpoint; its URL is never itself an authority.
    fn verify(&self, target: &crate::configuration::policy::RunTarget) -> Result<(), CoreError> {
        let intent: Value = serde_json::from_str(&self.0).map_err(|_| CoreError::InvalidValue {
            field: "NativeConnection",
        })?;
        let model = target.model.as_deref().ok_or(CoreError::Unavailable)?;
        let endpoint = target.endpoint.as_deref().ok_or(CoreError::Unavailable)?;
        if intent.get("provider").and_then(Value::as_str) != Some(target.provider.as_str())
            || intent.get("model").and_then(Value::as_str) != Some(model)
            || intent.get("url").and_then(Value::as_str) != Some(endpoint)
        {
            return Err(CoreError::ConfigurationChanged);
        }
        if !intent
            .get("headers")
            .and_then(Value::as_object)
            .is_some_and(|headers| headers.is_empty())
        {
            return Err(CoreError::ConfigurationChanged);
        }
        let headers = intent
            .get("auth")
            .and_then(|auth| auth.get("extra_headers"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let headers: crate::api::HeaderTemplates =
            serde_json::from_value(headers).map_err(|_| CoreError::ConfigurationChanged)?;
        let wire_headers = intent
            .get("wire")
            .and_then(|wire| wire.get("default-headers"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let wire_headers: crate::api::HeaderTemplates =
            serde_json::from_value(wire_headers).map_err(|_| CoreError::ConfigurationChanged)?;
        target.verify_headers(&headers, &wire_headers)?;
        target.verify_credential(
            intent
                .get("auth")
                .and_then(|auth| auth.get("key"))
                .and_then(Value::as_str),
        )
    }
}
impl TryFrom<Box<RawValue>> for ConnectionIntent {
    type Error = CoreError;
    fn try_from(value: Box<RawValue>) -> Result<Self, CoreError> {
        if value.get().len() > limits::API_REQUEST_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self(Zeroizing::new(value.get().to_owned())))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AbortRequest {
    scope: RunScope,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ContinueRequest {
    scope: RunScope,
    reason: Option<ContinuationReason>,
    turn_limit: Option<ModelTurnLimit>,
    call_id: Option<ToolCallId>,
    approved: Option<bool>,
}

struct Owner {
    scope: ReadScope,
    run_scope: RunScope,
    publish: bool,
    terminal: Option<CoreError>,
}
struct PreparedStart {
    workspace: PreparedRun,
    connection: Arc<ChatConnection>,
    prompt: Option<Message>,
    options: AgentOptions,
    budget: BudgetLimits,
    retry: Option<RetryConfiguration>,
    edit_policy: crate::edit::prepare::ParentPolicy,
}
struct Starting {
    claim: RunClaim,
    model_revision: crate::models::store::MetadataRevision,
    task: Option<JoinHandle<Result<PreparedStart, CoreError>>>,
    input: Option<(PromptInput, crate::configuration::policy::RunTarget)>,
    credential: Option<credential::CredentialPreparation>,
    notified: bool,
}
enum Work {
    Idle,
    Preparing(JoinHandle<(ModelTurn, Result<HttpRequest, ApiError>)>),
    Model {
        id: RpcId,
    },
    Command {
        id: RpcId,
    },
    Read {
        id: RpcId,
        observation: Option<files::ObservationStamp>,
    },
    FileCapture(Box<files::FileCapture>),
    FileValidation(Box<files::FileValidation>),
    Editor(Box<editor::EditorCall>),
    NativeEdit(Box<native_edit::NativeEdit>),
    Tool(Box<AgentTool>),
}
struct Running {
    run: RunHandle,
    connection: Arc<ChatConnection>,
    budget: BudgetId,
    retry: Option<RetryConfiguration>,
    edit_policy: crate::edit::prepare::ParentPolicy,
    work: Work,
    terminal: Option<AgentStop>,
    waiting: bool,
    failure: Option<ApiError>,
}
enum Stage {
    Starting(Box<Starting>),
    Running(Box<Running>),
    Settled,
}
struct Operation {
    owner: Owner,
    stage: Stage,
}

struct SessionContext<'a> {
    api: &'a mut ApiRequests,
    commands: &'a mut Commands,
    reads: &'a mut ReadTools,
    pending: &'a mut PendingRequests,
}

#[derive(Default)]
pub(super) struct Sessions {
    operations: HashMap<RpcId, Operation>,
}
impl Sessions {
    pub fn contains(&self, id: &RpcId) -> bool {
        self.operations.contains_key(id)
    }
    pub fn is_empty(&self) -> bool {
        self.operations.is_empty()
    }
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.operations
            .values()
            .any(|op| &op.owner.scope.application_id == id)
    }
    pub fn cancel(&mut self, id: &RpcId) {
        if let Some(op) = self.operations.get_mut(id) {
            op.owner.publish = false;
            op.owner.terminal = Some(CoreError::Cancelled);
        }
    }
    pub fn abort(&mut self, host: &mut Host, params: Value) -> Result<Value, Fault> {
        let request: AbortRequest = serde_json::from_value(params).map_err(|_| Fault::params())?;
        let op = self
            .operations
            .values_mut()
            .find(|op| op.owner.run_scope == request.scope)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        op.owner.terminal = Some(CoreError::Cancelled);
        revoke(host, op).map_err(fault)?;
        Ok(json!({"status":"revoked","scope":request.scope}))
    }
    pub fn resume(
        &mut self,
        host: &mut Host,
        params: Value,
    ) -> Result<(Value, Option<Value>), Fault> {
        let request: ContinueRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let (prompt_id, op) = self
            .operations
            .iter_mut()
            .find(|(_, op)| op.owner.run_scope == request.scope)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        if op.owner.terminal.is_some() || !host.owns_read_scope(&op.owner.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        let Stage::Running(run) = &mut op.stage else {
            return Err(fault(CoreError::Busy));
        };
        if matches!(&run.work, Work::Tool(call) if call.admission() == ToolAdmission::Repetition)
            && run.waiting
            && request.reason.is_none()
            && request.turn_limit.is_none()
        {
            let valid = matches!(&run.work, Work::Tool(call) if request.call_id.as_ref() == Some(call.id()));
            let approved = request.approved.ok_or_else(Fault::params)?;
            if !valid {
                return Err(fault(CoreError::StaleOwner));
            }
            let Work::Tool(call) = std::mem::replace(&mut run.work, Work::Idle) else {
                return Err(fault(CoreError::CleanupFailed));
            };
            let actor = host.actor_mut(&op.owner.scope).map_err(fault)?;
            let call = (*call)
                .decide_repetition(
                    actor,
                    if approved {
                        crate::security::UserDecision::Approved
                    } else {
                        crate::security::UserDecision::Rejected
                    },
                )
                .map_err(fault)?;
            let completed = if approved {
                run.work = Work::Tool(Box::new(call));
                None
            } else {
                let call_id = call.id().clone();
                call.complete(
                    actor,
                    crate::application::ToolOutcome::Rejected,
                    crate::application::ToolOutcome::Rejected.summary(),
                )
                .map_err(fault)?;
                Some(json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Rejected}))
            };
            run.waiting = false;
            let notification = completed
                .map(|payload| event(host, prompt_id, &op.owner, "session/tool_result", payload))
                .transpose()
                .map_err(fault)?
                .flatten();
            return Ok((
                json!({"status":"continued","scope":request.scope}),
                notification,
            ));
        }
        if request.call_id.is_some() || request.approved.is_some() {
            return Err(Fault::params());
        }
        if !matches!(run.work, Work::Idle) || !run.waiting {
            return Err(fault(CoreError::Busy));
        }
        let actor = host.actor_mut(&op.owner.scope).map_err(fault)?;
        match (
            request.reason,
            request.turn_limit,
            actor.agent_phase(&run.run).map_err(fault)?,
        ) {
            (Some(expected), None, AgentPhase::Continuation(reason)) if expected == reason => {
                actor.continue_agent(&run.run, reason).map_err(fault)?;
            }
            (None, Some(limit), AgentPhase::Ready) => {
                actor.extend_agent_turns(&run.run, limit).map_err(fault)?
            }
            _ => return Err(fault(CoreError::Rejected)),
        }
        run.waiting = false;
        Ok((json!({"status":"continued","scope":request.scope}), None))
    }
    pub fn start(&mut self, host: &mut Host, id: RpcId, params: Value) -> Result<(), Fault> {
        if self.contains(&id) || self.operations.len() >= limits::MAX_APPLICATIONS {
            return Err(fault(CoreError::Limit));
        }
        let request: PromptRequest = serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        let mut input = request.arguments;
        let mut target = host
            .prompt_target(&request.scope, input.config_revision)
            .map_err(fault)?;
        input.connection.verify(&target).map_err(fault)?;
        if target.interop_host().map_err(fault)?.is_some() && !host.editor_credential_available() {
            return Err(fault(CoreError::Unavailable));
        }
        let model_revision = host.model_revision(&request.scope).map_err(fault)?;
        if input.model_revision != model_revision {
            return Err(fault(CoreError::ConfigurationChanged));
        }
        let (tools, reasoning, parameters) = host
            .run_model_policy(&request.scope, &target)
            .map_err(fault)?;
        input.tools_enabled &= tools;
        target.model_parameters = parameters;
        target.reasoning = reasoning;
        let claim = host
            .actor_mut(&request.scope)
            .map_err(fault)?
            .claim_run(
                &request.scope.session_id,
                ClaimIntent {
                    workspace: RequestedWorkspace::try_from(input.root.clone()).map_err(fault)?,
                    mode: input.mode,
                    tool_limit: input.tool_limit,
                    timeout: input.timeout_ms.0,
                    config_revision: input.config_revision,
                    policy_revision: input.policy_revision,
                },
            )
            .map_err(fault)?;
        self.operations.insert(
            id,
            Operation {
                owner: Owner {
                    scope: request.scope,
                    run_scope: claim.scope().clone(),
                    publish: true,
                    terminal: None,
                },
                stage: Stage::Starting(Box::new(Starting {
                    claim,
                    model_revision,
                    task: None,
                    input: Some((input, target)),
                    credential: None,
                    notified: false,
                })),
            },
        );
        Ok(())
    }
    fn spawn_start(
        claim: &RunClaim,
        input: PromptInput,
        target: crate::configuration::policy::RunTarget,
        key: Option<crate::api::SecretString>,
    ) -> Result<JoinHandle<Result<PreparedStart, CoreError>>, CoreError> {
        let lease = claim.lease()?;
        let worker_claim = claim.clone();
        Ok(tokio::task::spawn_blocking(move || {
            let _lease = lease;
            let workspace = worker_claim.prepare_workspace()?;
            worker_claim.check_live()?;
            let connection = target.prepare_connection(
                &input.connection.0,
                worker_claim.scope().session_id(),
                key,
            )?;
            let prompt = input.prompt.map(Message::try_from).transpose()?;
            worker_claim.check_live()?;
            Ok(PreparedStart {
                workspace,
                connection: Arc::new(connection),
                prompt,
                options: AgentOptions {
                    turn_limit: input.turn_limit,
                    tools_enabled: input.tools_enabled,
                    editor_available: input.editor_available,
                },
                budget: input.budget,
                retry: input.retry,
                edit_policy: input.edit_policy,
            })
        }))
    }
    fn prepare_start(
        host: &Host,
        pending: &mut PendingRequests,
        id: &RpcId,
        owner: &mut Owner,
        starting: &mut Starting,
        messages: &mut Vec<Value>,
    ) -> Result<bool, CoreError> {
        if starting.credential.is_none()
            && owner.terminal.is_none()
            && let Err(error) = Self::start_credential(host, pending, id, starting, messages)
        {
            owner.terminal = Some(error);
        }
        let key = if let Some(credential) = &mut starting.credential {
            match credential.poll(host, &starting.claim, owner.terminal.is_some(), messages)? {
                None => return Ok(false),
                Some(Ok(key)) => Some(key),
                Some(Err(error)) => {
                    if owner.terminal.is_none() {
                        owner.terminal = Some(error);
                    }
                    None
                }
            }
        } else {
            None
        };
        starting.credential = None;
        let (input, target) = starting.input.take().ok_or(CoreError::CleanupFailed)?;
        if owner.terminal.is_none() {
            match Self::spawn_start(&starting.claim, input, target, key) {
                Ok(task) => starting.task = Some(task),
                Err(error) => owner.terminal = Some(error),
            }
        }
        Ok(true)
    }
    fn start_credential(
        host: &Host,
        pending: &mut PendingRequests,
        id: &RpcId,
        starting: &mut Starting,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        let (_, target) = starting.input.as_ref().ok_or(CoreError::CleanupFailed)?;
        if target.interop_host()?.is_some() {
            starting.credential = Some(credential::CredentialPreparation::start(
                host,
                pending,
                id,
                &starting.claim,
                target,
                messages,
            )?);
        }
        Ok(())
    }
    pub fn disconnect(&mut self, host: &mut Host) -> Result<(), CoreError> {
        for op in self.operations.values_mut() {
            op.owner.publish = false;
            op.owner.terminal = Some(CoreError::Cancelled);
            revoke(host, op)?;
        }
        Ok(())
    }
    /// API drain has joined every exchange/backoff/observer and dropped its
    /// retained model tickets. No native request remains executable afterward.
    pub fn api_drained(&mut self) {
        for op in self.operations.values_mut() {
            if let Stage::Running(run) = &mut op.stage
                && matches!(run.work, Work::Model { .. })
            {
                run.work = Work::Idle;
            }
        }
    }
    pub fn route_api(
        &mut self,
        host: &mut Host,
        message: Value,
    ) -> Result<Option<Value>, CoreError> {
        let Some(request) = message
            .get("params")
            .and_then(|params| params.get("request_id"))
            .and_then(RpcId::parse)
        else {
            return Ok(Some(message));
        };
        let Some((id, op)) = self.operations.iter_mut().find(|(_, op)| {
            matches!(&op.stage,
            Stage::Running(running) if match &running.work { Work::Model { id } => id == &request, _ => false })
        }) else {
            return Ok(Some(message));
        };
        if op.owner.terminal.is_some() || !host.owns_read_scope(&op.owner.scope) {
            return Ok(None);
        }
        if message.get("method").and_then(Value::as_str) != Some("api/delta") {
            return Err(CoreError::CleanupFailed);
        }
        let Some(delta) = message.get("params").and_then(|params| params.get("delta")) else {
            return Err(CoreError::CleanupFailed);
        };
        match event(host, id, &op.owner, "session/chunk", json!({"delta":delta})) {
            Ok(message) => Ok(message),
            Err(CoreError::Limit) => {
                op.owner.terminal = Some(CoreError::Limit);
                revoke(host, op)?;
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
    pub fn tick(
        &mut self,
        host: &mut Host,
        api: &mut ApiRequests,
        commands: &mut Commands,
        reads: &mut ReadTools,
        pending: &mut PendingRequests,
    ) -> Result<Vec<Value>, CoreError> {
        let mut ctx = SessionContext {
            api,
            commands,
            reads,
            pending,
        };
        let mut messages = Vec::new();
        loop {
            while let Some(delivery) = ctx.commands.take_call() {
                self.deliver_command(host, delivery, &mut messages)?;
            }
            while let Some(delivery) = ctx.reads.take_call() {
                self.deliver_read(host, &mut ctx, delivery, &mut messages)?;
            }
            while let Some(delivery) = ctx.api.take_model() {
                self.deliver_model(host, delivery, &mut messages)?;
            }
            let ids: Vec<_> = self.operations.keys().cloned().collect();
            for id in ids {
                // Keep the resource-owning operation in the registry across every
                // fallible transition. An outbound framing failure must not detach
                // an unjoined preparation task or lose its cancellation owner.
                let op = self
                    .operations
                    .get_mut(&id)
                    .ok_or(CoreError::CleanupFailed)?;
                if !host.owns_read_scope(&op.owner.scope) {
                    op.owner.publish = false;
                    if op.owner.terminal.is_none() {
                        op.owner.terminal = Some(CoreError::StaleOwner);
                    }
                }
                if op.owner.terminal.is_some() {
                    revoke(host, op)?;
                }
                let done = match &op.stage {
                    Stage::Starting(_) => Self::starting(host, &mut ctx, &id, op, &mut messages)?,
                    Stage::Running(_) => Self::running(host, &mut ctx, &id, op, &mut messages)?,
                    Stage::Settled => true,
                };
                if done {
                    self.operations.remove(&id);
                }
            }
            if !ctx.reads.has_completed() {
                break;
            }
        }
        Ok(messages)
    }
    fn starting(
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        id: &RpcId,
        op: &mut Operation,
        messages: &mut Vec<Value>,
    ) -> Result<bool, CoreError> {
        let Stage::Starting(starting) = &mut op.stage else {
            return Err(CoreError::CleanupFailed);
        };
        let owner = &mut op.owner;
        if owner.terminal.is_none() {
            owner.terminal = starting.claim.check_live().err();
        }
        if owner.terminal.is_none()
            && (!host.configuration_current(&owner.scope, starting.claim.scope().config_revision())
                || host.model_revision(&owner.scope).ok() != Some(starting.model_revision))
        {
            owner.terminal = Some(CoreError::ConfigurationChanged);
        }
        if owner.terminal.is_none()
            && starting
                .credential
                .as_ref()
                .is_some_and(|credential| credential.expired())
        {
            owner.terminal = Some(CoreError::Deadline);
        }
        if owner.terminal.is_some() {
            host.actor_mut(&owner.scope)?
                .cancel_claim(&starting.claim)?;
        }
        if !starting.notified {
            starting.notified = true;
            if let Some(message) = event(
                host,
                id,
                owner,
                "session/state",
                json!({"phase":"preparing"}),
            )? {
                messages.push(message);
            }
        }
        if starting.input.is_some()
            && !Self::prepare_start(host, ctx.pending, id, owner, starting, messages)?
        {
            return Ok(false);
        }
        if starting
            .task
            .as_ref()
            .is_some_and(|task| !task.is_finished())
        {
            return Ok(false);
        }
        let prepared = match starting.task.take() {
            Some(task) => task
                .now_or_never()
                .ok_or(CoreError::CleanupFailed)?
                .map_err(|_| CoreError::CleanupFailed)?,
            None => Err(CoreError::Cancelled),
        };
        let prepared = match prepared {
            Ok(prepared) if owner.terminal.is_none() => prepared,
            result => {
                let failure = result.err();
                if owner.terminal.is_none() {
                    owner.terminal = failure;
                }
                // Dropping the completed candidate precedes actual claim release.
                host.actor_mut(&owner.scope)?
                    .finish_claim(&starting.claim)?;
                op.stage = Stage::Settled;
                finish_response(host, id, owner, None, None, messages)?;
                return Ok(true);
            }
        };
        // A publication during preparation invalidates the captured receipt.
        if !host.configuration_current(&owner.scope, starting.claim.scope().config_revision())
            || host.model_revision(&owner.scope).ok() != Some(starting.model_revision)
        {
            owner.terminal = Some(CoreError::ConfigurationChanged);
            drop(prepared);
            host.actor_mut(&owner.scope)?
                .finish_claim(&starting.claim)?;
            op.stage = Stage::Settled;
            finish_response(host, id, owner, None, None, messages)?;
            return Ok(true);
        }
        let run = host
            .actor_mut(&owner.scope)?
            .activate_claim(prepared.workspace)?;
        if let Err(error) =
            host.actor_mut(&owner.scope)?
                .start_agent(&run, prepared.options, prepared.prompt)
        {
            owner.terminal = Some(error);
            let actor = host.actor_mut(&owner.scope)?;
            actor.cancel(&run)?;
            actor.finish(&run)?;
            op.stage = Stage::Settled;
            finish_response(host, id, owner, None, None, messages)?;
            return Ok(true);
        }
        let budget = match ctx.api.open_run_budget(host, &run, prepared.budget) {
            Ok(budget) => budget,
            Err(error) => {
                owner.terminal = Some(error);
                let actor = host.actor_mut(&owner.scope)?;
                actor.cancel(&run)?;
                actor.finish(&run)?;
                op.stage = Stage::Settled;
                finish_response(host, id, owner, None, None, messages)?;
                return Ok(true);
            }
        };
        op.stage = Stage::Running(Box::new(Running {
            run,
            connection: prepared.connection,
            budget,
            retry: prepared.retry,
            edit_policy: prepared.edit_policy,
            work: Work::Idle,
            terminal: None,
            waiting: false,
            failure: None,
        }));
        if let Some(message) = event(host, id, owner, "session/state", json!({"phase":"ready"}))? {
            messages.push(message);
        }
        Ok(false)
    }
    fn running(
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        id: &RpcId,
        op: &mut Operation,
        messages: &mut Vec<Value>,
    ) -> Result<bool, CoreError> {
        let Stage::Running(running) = &mut op.stage else {
            return Err(CoreError::CleanupFailed);
        };
        let owner = &mut op.owner;
        if owner.terminal.is_none() {
            owner.terminal = running.run.check_live().err();
        }
        if let Work::NativeEdit(edit) = &mut running.work
            && let Some((outcome, text)) = edit.poll(
                host,
                ctx,
                id,
                &owner.scope,
                owner.terminal.as_ref(),
                messages,
            )?
        {
            let Work::NativeEdit(edit) = std::mem::replace(&mut running.work, Work::Idle) else {
                return Err(CoreError::CleanupFailed);
            };
            let call = edit.into_call();
            let call_id = call.id().clone();
            running.waiting = false;
            if let Err(error) = call.complete(host.actor_mut(&owner.scope)?, outcome, &text) {
                owner.terminal = Some(error);
            }
            if let Some(message) = event(
                host,
                id,
                owner,
                "session/tool_result",
                json!({"call_id":call_id,"outcome":outcome}),
            )? {
                messages.push(message);
            }
        }
        if owner.terminal.is_some() {
            host.actor_mut(&owner.scope)?.cancel(&running.run)?;
        }
        if matches!(&running.work, Work::Preparing(task) if task.is_finished()) {
            let Work::Preparing(task) = std::mem::replace(&mut running.work, Work::Idle) else {
                return Err(CoreError::CleanupFailed);
            };
            let (turn, prepared) = task
                .now_or_never()
                .ok_or(CoreError::CleanupFailed)?
                .map_err(|_| CoreError::CleanupFailed)?;
            match prepared {
                Ok(request) if owner.terminal.is_none() => {
                    let native_id = RpcId::String(format!(
                        "s:model:{}:{}",
                        host.request_scope()?.as_str(),
                        turn.id().as_str()
                    ));
                    match ctx.api.start_model(
                        host,
                        native_id.clone(),
                        turn,
                        request,
                        running.budget.clone(),
                        running.retry.clone(),
                    ) {
                        Ok(()) => running.work = Work::Model { id: native_id },
                        Err(rejected) => {
                            let (_fault, turn) = *rejected;
                            drop(turn);
                            owner.terminal = Some(CoreError::Rejected);
                        }
                    }
                }
                result => {
                    drop(turn);
                    if owner.terminal.is_none() {
                        owner.terminal = Some(match result {
                            Err(ApiError::RunDeadline | ApiError::Deadline) => CoreError::Deadline,
                            Err(ApiError::Cancelled) => CoreError::Cancelled,
                            Err(ApiError::Limit) => CoreError::Limit,
                            _ => CoreError::InvalidToolOutput,
                        });
                    }
                }
            }
        }
        if let Work::FileCapture(capture) = &mut running.work {
            let received = if owner.terminal.is_some() {
                capture.cancel(host, ctx)?;
                Some(Err(CoreError::Cancelled))
            } else {
                match capture.poll() {
                    Ok(Some(observation)) => Some(Ok(observation)),
                    Ok(None) => None,
                    Err(error) => Some(Err(error)),
                }
            };
            if let Some(received) = received {
                let Work::FileCapture(capture) = std::mem::replace(&mut running.work, Work::Idle)
                else {
                    return Err(CoreError::CleanupFailed);
                };
                let prepared = match received {
                    Ok(observation) => capture.prepare(observation),
                    Err(error) => Err(Box::new((error, capture.into_call()))),
                };
                match prepared {
                    Ok((call, plan, observation)) => {
                        let native_id = RpcId::String(format!(
                            "s:read:{}:{}",
                            host.request_scope()?.as_str(),
                            call.id().as_str()
                        ));
                        match ctx.reads.start_prepared_call(
                            host,
                            native_id.clone(),
                            call,
                            Some(plan),
                        ) {
                            Ok(()) => {
                                running.work = Work::Read {
                                    id: native_id,
                                    observation: Some(observation),
                                }
                            }
                            Err(rejected) => {
                                let (error, call) = *rejected;
                                Self::finish_read(
                                    host,
                                    id,
                                    owner,
                                    running,
                                    files::failed(call, error),
                                    messages,
                                )?;
                            }
                        }
                    }
                    Err(rejected) => {
                        let (error, call) = *rejected;
                        Self::finish_read(
                            host,
                            id,
                            owner,
                            running,
                            files::failed(call, error),
                            messages,
                        )?;
                    }
                }
            }
        }
        if let Work::FileValidation(validation) = &mut running.work {
            let current = if owner.terminal.is_some() {
                validation.cancel(host, ctx)?;
                Some(Err(CoreError::Cancelled))
            } else {
                validation.poll()
            };
            if let Some(current) = current {
                let Work::FileValidation(validation) =
                    std::mem::replace(&mut running.work, Work::Idle)
                else {
                    return Err(CoreError::CleanupFailed);
                };
                Self::finish_read(
                    host,
                    id,
                    owner,
                    running,
                    validation.into_delivery(current),
                    messages,
                )?;
            }
        }
        if let Work::Editor(editor) = &mut running.work
            && let Some((outcome, text)) = editor.poll(
                host,
                ctx,
                id,
                &owner.scope,
                owner.terminal.as_ref(),
                messages,
            )?
        {
            let Work::Editor(editor) = std::mem::replace(&mut running.work, Work::Idle) else {
                return Err(CoreError::CleanupFailed);
            };
            let mut editor = editor;
            let selection = editor.take_selection();
            let call = editor.into_call();
            let (call, outcome, text) = if let Some(selection) = selection {
                match native_edit::NativeEdit::start_selected(
                    host,
                    ctx,
                    id,
                    call,
                    running.edit_policy,
                    Some(selection),
                    messages,
                ) {
                    Ok(edit) => {
                        running.work = Work::NativeEdit(Box::new(edit));
                        return Ok(false);
                    }
                    Err(rejected) => {
                        let (_error, call) = *rejected;
                        (
                            call,
                            crate::application::ToolOutcome::Failed,
                            "ERROR: symbol edit could not be admitted".to_owned(),
                        )
                    }
                }
            } else {
                (call, outcome, text)
            };
            let call_id = call.id().clone();
            running.waiting = false;
            if let Err(error) = call.complete(host.actor_mut(&owner.scope)?, outcome, &text) {
                owner.terminal = Some(error);
            }
            if let Some(message) = event(
                host,
                id,
                owner,
                "session/tool_result",
                json!({"call_id":call_id,"outcome":outcome}),
            )? {
                messages.push(message);
            }
        }
        if owner.terminal.is_some() {
            host.actor_mut(&owner.scope)?.cancel(&running.run)?;
            if let Work::Read { id: read_id, .. } = &running.work {
                ctx.reads.cancel(read_id);
            }
            if matches!(running.work, Work::Tool(_)) {
                running.work = Work::Idle;
            }
        }
        if owner.terminal.is_none()
            && matches!(&running.work, Work::Tool(call) if call.admission() == ToolAdmission::Ready)
        {
            let symbol_edit =
                matches!(&running.work, Work::Tool(call) if call.name().as_str() == "edit_by_lsp");
            let route = match &running.work {
                Work::Tool(call) => call.route(),
                _ => None,
            };
            if route == Some(crate::security::ToolRoute::NativeCommand) {
                let Work::Tool(call) = std::mem::replace(&mut running.work, Work::Idle) else {
                    return Err(CoreError::CleanupFailed);
                };
                let native_id = RpcId::String(format!(
                    "s:tool:{}:{}",
                    host.request_scope()?.as_str(),
                    call.id().as_str()
                ));
                match ctx.commands.start_call(host, native_id.clone(), *call) {
                    Ok(()) => running.work = Work::Command { id: native_id },
                    Err(rejected) => {
                        let (_error, call) = *rejected;
                        let call_id = call.id().clone();
                        call.complete(
                            host.actor_mut(&owner.scope)?,
                            crate::application::ToolOutcome::Failed,
                            "ERROR: native command could not be admitted",
                        )?;
                        if let Some(message) = event(
                            host,
                            id,
                            owner,
                            "session/tool_result",
                            json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Failed}),
                        )? {
                            messages.push(message);
                        }
                    }
                }
            } else if route == Some(crate::security::ToolRoute::NativeRead)
                && host.editor_file_snapshot_available()
                && matches!(&running.work, Work::Tool(call) if call.name().as_str() == "read_file")
            {
                let Work::Tool(call) = std::mem::replace(&mut running.work, Work::Idle) else {
                    return Err(CoreError::CleanupFailed);
                };
                match files::FileCapture::start(host, ctx, id, *call, messages) {
                    Ok(capture) => running.work = Work::FileCapture(Box::new(capture)),
                    Err(rejected) => {
                        let (error, call) = *rejected;
                        Self::finish_read(
                            host,
                            id,
                            owner,
                            running,
                            files::failed(call, error),
                            messages,
                        )?;
                    }
                }
            } else if route == Some(crate::security::ToolRoute::NativeRead) {
                let Work::Tool(call) = std::mem::replace(&mut running.work, Work::Idle) else {
                    return Err(CoreError::CleanupFailed);
                };
                let native_id = RpcId::String(format!(
                    "s:read:{}:{}",
                    host.request_scope()?.as_str(),
                    call.id().as_str()
                ));
                match ctx.reads.start_call(host, native_id.clone(), *call) {
                    Ok(()) => {
                        running.work = Work::Read {
                            id: native_id,
                            observation: None,
                        }
                    }
                    Err(rejected) => {
                        let (_error, call) = *rejected;
                        let call_id = call.id().clone();
                        call.complete(
                            host.actor_mut(&owner.scope)?,
                            crate::application::ToolOutcome::Failed,
                            "ERROR: native read could not be admitted",
                        )?;
                        if let Some(message) = event(
                            host,
                            id,
                            owner,
                            "session/tool_result",
                            json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Failed}),
                        )? {
                            messages.push(message);
                        }
                    }
                }
            } else if route == Some(crate::security::ToolRoute::NativeEdit) && !symbol_edit {
                let Work::Tool(call) = std::mem::replace(&mut running.work, Work::Idle) else {
                    return Err(CoreError::CleanupFailed);
                };
                match native_edit::NativeEdit::start(
                    host,
                    ctx,
                    id,
                    *call,
                    running.edit_policy,
                    messages,
                ) {
                    Ok(edit) => running.work = Work::NativeEdit(Box::new(edit)),
                    Err(rejected) => {
                        let (_, call) = *rejected;
                        let call_id = call.id().clone();
                        call.complete(
                            host.actor_mut(&owner.scope)?,
                            crate::application::ToolOutcome::Failed,
                            "ERROR: native edit could not be admitted",
                        )?;
                        if let Some(message) = event(
                            host,
                            id,
                            owner,
                            "session/tool_result",
                            json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Failed}),
                        )? {
                            messages.push(message);
                        }
                    }
                }
            } else if route == Some(crate::security::ToolRoute::Editor) || symbol_edit {
                let Work::Tool(call) = std::mem::replace(&mut running.work, Work::Idle) else {
                    return Err(CoreError::CleanupFailed);
                };
                match editor::EditorCall::start(host, ctx, id, *call, messages) {
                    Ok(editor) => running.work = Work::Editor(Box::new(editor)),
                    Err(rejected) => {
                        let (_error, call) = *rejected;
                        let call_id = call.id().clone();
                        call.complete(
                            host.actor_mut(&owner.scope)?,
                            crate::application::ToolOutcome::Failed,
                            "ERROR: editor resource capture could not be admitted",
                        )?;
                        if let Some(message) = event(
                            host,
                            id,
                            owner,
                            "session/tool_result",
                            json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Failed}),
                        )? {
                            messages.push(message);
                        }
                    }
                }
            } else if !running.waiting {
                running.waiting = true;
                if let Some(message) = event(
                    host,
                    id,
                    owner,
                    "session/state",
                    json!({"phase":"tool_adapter_pending"}),
                )? {
                    messages.push(message);
                }
            }
        }
        if !matches!(running.work, Work::Idle) {
            return Ok(false);
        }
        if owner.terminal.is_some() || running.terminal.is_some() {
            if !running.run.drained() {
                return Ok(false);
            }
            let changes = host
                .actor_mut(&owner.scope)?
                .edits
                .conversation_changes(&owner.scope.session_id)?;
            let budget = ctx.api.close_run_budget(&running.run, &running.budget)?;
            let actor = host.actor_mut(&owner.scope)?;
            actor.finish(&running.run)?;
            let revision = actor
                .session_history(&owner.scope.session_id)
                .ok()
                .map(|history| history.revision());
            let terminal = running.terminal;
            let answer_message = if terminal == Some(AgentStop::Answer) && owner.terminal.is_none()
            {
                actor
                    .session_history(&owner.scope.session_id)
                    .ok()
                    .and_then(crate::history::History::answer_message)
                    .cloned()
            } else {
                None
            };
            let accounting = json!({"budget":budget,"changes":changes,"history_revision":revision,
                "answer_message":answer_message,"failure":running.failure.as_ref().map(ApiError::snapshot)});
            op.stage = Stage::Settled;
            finish_response(host, id, owner, terminal, Some(accounting), messages)?;
            return Ok(true);
        }
        match host.actor_mut(&owner.scope)?.agent_phase(&running.run)? {
            AgentPhase::Ready if !running.waiting => {
                match host.actor_mut(&owner.scope)?.begin_model_turn(&running.run) {
                    Ok(turn) => {
                        let connection = running.connection.clone();
                        running.work = Work::Preparing(tokio::task::spawn_blocking(move || {
                            let result = connection.prepare_turn(&turn);
                            (turn, result)
                        }));
                    }
                    Err(CoreError::Limit) => {
                        running.waiting = true;
                        if let Some(message) = event(
                            host,
                            id,
                            owner,
                            "session/state",
                            json!({"phase":"turn_limit"}),
                        )? {
                            messages.push(message);
                        }
                    }
                    Err(error) => owner.terminal = Some(error),
                }
            }
            AgentPhase::Continuation(
                reason @ (ContinuationReason::Empty | ContinuationReason::ThoughtOnly),
            ) => {
                host.actor_mut(&owner.scope)?
                    .continue_agent(&running.run, reason)?;
            }
            AgentPhase::Tools if !running.waiting => {
                match host.actor_mut(&owner.scope)?.next_agent_tool(&running.run) {
                    Ok(call) => match call.admission() {
                        ToolAdmission::Refused(_) => {
                            let call_id = call.id().clone();
                            call.complete(
                                host.actor_mut(&owner.scope)?,
                                crate::application::ToolOutcome::Rejected,
                                crate::application::ToolOutcome::Rejected.summary(),
                            )?;
                            if let Some(message) = event(
                                host,
                                id,
                                owner,
                                "session/tool_result",
                                json!({"call_id":call_id,"outcome":crate::application::ToolOutcome::Rejected}),
                            )? {
                                messages.push(message);
                            }
                        }
                        ToolAdmission::Repetition => {
                            running.waiting = true;
                            let payload = json!({"phase":"repetition","call_id":call.id(),"tool_name":call.name()});
                            running.work = Work::Tool(Box::new(call));
                            if let Some(message) = event(host, id, owner, "session/state", payload)?
                            {
                                messages.push(message);
                            }
                        }
                        ToolAdmission::Ready => running.work = Work::Tool(Box::new(call)),
                    },
                    Err(error) => owner.terminal = Some(error),
                }
            }
            AgentPhase::Terminal(reason) => running.terminal = Some(reason),
            phase if !running.waiting => {
                running.waiting = true;
                if let Some(message) =
                    event(host, id, owner, "session/state", json!({"phase":phase}))?
                {
                    messages.push(message);
                }
            }
            _ => {}
        }
        Ok(false)
    }
    fn deliver_command(
        &mut self,
        host: &mut Host,
        delivery: CommandDelivery,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        let Some((id, op)) = self
            .operations
            .iter_mut()
            .find(|(_, op)| op.owner.run_scope == *delivery.call.run().scope())
        else {
            return Err(CoreError::CleanupFailed);
        };
        let Stage::Running(run) = &mut op.stage else {
            return Err(CoreError::CleanupFailed);
        };
        if !matches!(&run.work, Work::Command { id } if id == &delivery.id) {
            return Err(CoreError::CleanupFailed);
        }
        run.work = Work::Idle;
        run.waiting = false;
        let text = match delivery.result {
            Ok(value) => value
                .get("text")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string()),
            Err(_) => delivery.outcome.summary().to_owned(),
        };
        let call_id = delivery.call.id().clone();
        if let Err(error) =
            delivery
                .call
                .complete(host.actor_mut(&op.owner.scope)?, delivery.outcome, &text)
        {
            op.owner.terminal = Some(error);
        }
        if let Some(message) = event(
            host,
            id,
            &op.owner,
            "session/tool_result",
            json!({"call_id":call_id,"outcome":delivery.outcome}),
        )? {
            messages.push(message);
        }
        Ok(())
    }
    fn deliver_read(
        &mut self,
        host: &mut Host,
        ctx: &mut SessionContext<'_>,
        mut delivery: ReadDelivery,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        let Some((id, op)) = self
            .operations
            .iter_mut()
            .find(|(_, op)| op.owner.run_scope == *delivery.call.run().scope())
        else {
            return Err(CoreError::CleanupFailed);
        };
        let Stage::Running(run) = &mut op.stage else {
            return Err(CoreError::CleanupFailed);
        };
        if !matches!(&run.work, Work::Read {id, ..} if id == &delivery.id) {
            return Err(CoreError::CleanupFailed);
        }
        let Work::Read { observation, .. } = std::mem::replace(&mut run.work, Work::Idle) else {
            return Err(CoreError::CleanupFailed);
        };
        if let Some(observation) = observation
            && delivery.outcome == crate::application::ToolOutcome::Ok
            && op.owner.terminal.is_none()
            && run.run.check_live().is_ok()
        {
            match files::FileValidation::start(host, ctx, id, delivery, observation, messages) {
                Ok(validation) => {
                    run.work = Work::FileValidation(Box::new(validation));
                    return Ok(());
                }
                Err(rejected) => {
                    let (_error, mut original) = *rejected;
                    original.outcome = crate::application::ToolOutcome::Failed;
                    original.text = "ERROR: live file source could not be revalidated".to_owned();
                    delivery = original;
                }
            }
        }
        Self::finish_read(host, id, &mut op.owner, run, delivery, messages)
    }
    fn finish_read(
        host: &mut Host,
        id: &RpcId,
        owner: &mut Owner,
        run: &mut Running,
        mut delivery: ReadDelivery,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        run.work = Work::Idle;
        run.waiting = false;
        if host.editor_file_snapshot_available()
            && delivery.call.name().as_str() == "read_file"
            && let Some(message) = files::release(host, id, &delivery.call)?
        {
            messages.push(message);
        }
        let live = delivery.call.run().check_live();
        if owner.terminal.is_some() || live.is_err() {
            delivery.outcome = if matches!(
                owner.terminal,
                Some(CoreError::Deadline | CoreError::ApprovalExpired)
            ) || matches!(live, Err(CoreError::Deadline))
            {
                crate::application::ToolOutcome::Timeout
            } else {
                crate::application::ToolOutcome::Cancelled
            };
            delivery.text = delivery.outcome.summary().to_owned();
        }
        let call_id = delivery.call.id().clone();
        let actor = host.actor_mut(&owner.scope)?;
        actor.complete_tool(delivery.call.run(), &call_id, delivery.outcome)?;
        if let Err(error) = delivery
            .call
            .complete(actor, delivery.outcome, &delivery.text)
        {
            owner.terminal = Some(error);
        }
        if let Some(message) = event(
            host,
            id,
            owner,
            "session/tool_result",
            json!({"call_id":call_id,"outcome":delivery.outcome}),
        )? {
            messages.push(message);
        }
        Ok(())
    }
    fn deliver_model(
        &mut self,
        host: &mut Host,
        delivery: ModelDelivery,
        messages: &mut Vec<Value>,
    ) -> Result<(), CoreError> {
        let Some((id, op)) = self
            .operations
            .iter_mut()
            .find(|(_, op)| op.owner.run_scope == *delivery.turn.run().scope())
        else {
            return Err(CoreError::CleanupFailed);
        };
        let Stage::Running(run) = &mut op.stage else {
            return Err(CoreError::CleanupFailed);
        };
        if !matches!(run.work, Work::Model { .. }) {
            return Err(CoreError::CleanupFailed);
        }
        run.work = Work::Idle;
        run.waiting = false;
        if op.owner.terminal.is_some()
            || !host.owns_read_scope(&op.owner.scope)
            || run.run.check_live().is_err()
        {
            op.owner.terminal = Some(CoreError::Cancelled);
            drop(delivery);
            return Ok(());
        }
        let actor = host.actor_mut(&op.owner.scope)?;
        match delivery.result {
            Ok(reply) => {
                if let Err(error) = delivery.turn.complete(actor, *reply) {
                    op.owner.terminal = Some(error);
                }
            }
            Err(error) => {
                delivery.turn.failed(actor)?;
                run.terminal = Some(AgentStop::Failed);
                run.failure = Some(error);
            }
        }
        if let Some(message) = event(
            host,
            id,
            &op.owner,
            "session/accounting",
            json!({"budget":delivery.budget,"circuit":delivery.circuit}),
        )? {
            messages.push(message);
        }
        Ok(())
    }
}

fn revoke(host: &mut Host, op: &Operation) -> Result<(), CoreError> {
    let actor = host.actor_mut(&op.owner.scope)?;
    match &op.stage {
        Stage::Starting(starting) => actor.cancel_claim(&starting.claim),
        Stage::Running(running) => actor.cancel(&running.run),
        Stage::Settled => Ok(()),
    }
}
fn event(
    host: &mut Host,
    id: &RpcId,
    owner: &Owner,
    method: &'static str,
    payload: Value,
) -> Result<Option<Value>, CoreError> {
    if !owner.publish || !host.owns_read_scope(&owner.scope) {
        return Ok(None);
    }
    let sequence = host
        .actor_mut(&owner.scope)?
        .next_session_event(&owner.scope.session_id)?;
    let message = json!({"jsonrpc":"2.0","method":method,"params":{"request_id":id.value(),
        "connection_epoch":host.request_scope()?.as_str(),"scope":owner.run_scope,"sequence":sequence,"event":payload}});
    if message.to_string().len() > host.frame_limit().as_usize() {
        return Err(CoreError::Limit);
    }
    Ok(Some(message))
}
fn finish_response(
    host: &mut Host,
    id: &RpcId,
    owner: &Owner,
    terminal: Option<AgentStop>,
    accounting: Option<Value>,
    messages: &mut Vec<Value>,
) -> Result<(), CoreError> {
    if owner.publish {
        let error = owner.terminal.as_ref().map(|error| match error {
            CoreError::Cancelled | CoreError::StaleOwner => "cancelled",
            CoreError::Deadline => "timeout",
            CoreError::ConfigurationChanged => "stale_configuration",
            CoreError::CredentialUnavailable => "credential_unavailable",
            _ => "failed",
        });
        let status = error.unwrap_or(match terminal {
            Some(AgentStop::Failed | AgentStop::ProviderStopped) => "failed",
            Some(AgentStop::ContentFiltered) => "rejected",
            _ => "completed",
        });
        // The notification envelope already carries exact RunScope. Do not
        // duplicate it inside the event and overflow otherwise valid small frames.
        let payload = json!({"status":status,"terminal":terminal,"accounting":accounting});
        if let Some(message) = event(host, id, owner, "session/terminal", payload.clone())? {
            messages.push(message);
        }
        let mut reply = payload;
        reply
            .as_object_mut()
            .ok_or(CoreError::InvalidToolOutput)?
            .insert("scope".to_owned(), json!(owner.run_scope));
        messages.push(protocol::success(id, reply));
    }
    Ok(())
}
fn fault(error: CoreError) -> Fault {
    let status = match error {
        CoreError::StaleOwner => "stale_owner",
        CoreError::Busy => "busy",
        CoreError::Limit => "resource_limit",
        CoreError::ConfigurationChanged => "stale_configuration",
        CoreError::Unavailable => "configuration_unavailable",
        _ => "invalid_request",
    };
    Fault {
        code: crate::constants::protocol::error_codes::INVALID_STATE,
        message: "Native run request refused",
        status,
    }
}
