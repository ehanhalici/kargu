//! Native conversation ordering under the application's existing foreground
//! claim. IO owners receive consuming tickets; only this actor commits history.

mod response;
pub use response::AssistantTurn;

use super::{ApplicationActor, RunHandle, RunLease, RunPurpose, ToolOutcome};
use crate::{
    constants::limits,
    domain::{MessageId, ModelTurnId, ToolCallId, ToolName},
    error::CoreError,
    history::{HistoryRevision, Message, Role, StoredMessage},
    security::{ToolRoute, UserDecision},
};
use response::Finish;
use serde::{Deserialize, Serialize};
use serde_json::{Value, value::RawValue};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, sync::Arc};

/// Positive number of complete model turns, independent of tool/API attempts.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(try_from = "u32")]
pub struct ModelTurnLimit(u32);
impl TryFrom<u32> for ModelTurnLimit {
    type Error = CoreError;
    fn try_from(value: u32) -> Result<Self, CoreError> {
        if value == 0 || value > limits::AGENT_MODEL_TURNS {
            return Err(CoreError::InvalidValue {
                field: "ModelTurnLimit",
            });
        }
        Ok(Self(value))
    }
}
#[derive(Clone, Copy, Default, Debug, Serialize)]
struct ModelTurns(u32);

/// Optional editor capabilities have already been captured by the run's adapter.
/// The native catalog still decides route, safety, schema and permitted mode.
pub struct AgentOptions {
    /// Total model-turn cap; native HTTP retries do not reset it.
    pub turn_limit: ModelTurnLimit,
    /// An explicit disabled-tools selection advertises and dispatches no tools.
    pub tools_enabled: bool,
    /// Canonical live optional capabilities, never aliases or executable definitions.
    pub editor_available: Vec<ToolName>,
}

/// Why the completed model turn needs another controlled conversation step.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContinuationReason {
    /// Completed thought-only reply without an answer or tools.
    ThoughtOnly,
    /// Completed empty reply without tools.
    Empty,
    /// Provider output ceiling; continuation is a separate explicit decision.
    Length,
}
/// Native terminal disposition, independent of user-facing response text.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStop {
    /// A complete user-visible answer.
    Answer,
    /// Provider content filter refused the turn.
    ContentFiltered,
    /// Unknown provider terminal reason is never treated as a successful answer.
    ProviderStopped,
    /// Native provider exchange failed after its own retry policy.
    Failed,
}
/// Detached observation of the actor's current conversation phase.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "phase", content = "reason", rename_all = "snake_case")]
pub enum AgentPhase {
    /// May capture the next model request.
    Ready,
    /// One model ticket is awaiting actual provider completion.
    Model,
    /// A committed tool batch still has undispatched calls.
    Tools,
    /// One tool ticket must settle before advancing.
    Tool,
    /// A completed reply needs a controlled continuation.
    Continuation(ContinuationReason),
    /// The conversation can release once all resources have joined.
    Terminal(AgentStop),
}

enum Phase {
    Ready,
    Model {
        id: ModelTurnId,
        revision: HistoryRevision,
    },
    Tools,
    Tool {
        id: ToolCallId,
        admission: ToolAdmission,
    },
    Continuation(ContinuationReason),
    Terminal(AgentStop),
}
impl Phase {
    fn view(&self) -> AgentPhase {
        match self {
            Self::Ready => AgentPhase::Ready,
            Self::Model { .. } => AgentPhase::Model,
            Self::Tools => AgentPhase::Tools,
            Self::Tool { .. } => AgentPhase::Tool,
            Self::Continuation(reason) => AgentPhase::Continuation(*reason),
            Self::Terminal(reason) => AgentPhase::Terminal(*reason),
        }
    }
}

pub(super) struct AgentMachine {
    options: AgentOptions,
    turns: ModelTurns,
    phase: Phase,
    repeated: Option<Repetition>,
}
struct Repetition {
    signature: [u8; 32],
    count: RepeatCount,
}
struct RepeatCount(u8);
impl AgentMachine {
    pub(super) fn terminal(&self) -> bool {
        matches!(self.phase, Phase::Terminal(_))
    }
    pub(super) fn check_dispatch(&self, id: &ToolCallId) -> Result<(), CoreError> {
        match &self.phase {
            Phase::Tool {
                id: current,
                admission: ToolAdmission::Ready,
            } if current == id => Ok(()),
            _ => Err(CoreError::Rejected),
        }
    }
}

/// One actual model exchange. Keep this ticket in the IO task until it joins,
/// including after cancellation; its lease prevents premature run release.
#[must_use = "Retain the model ticket until the actual provider operation has joined"]
pub struct ModelTurn {
    run: RunHandle,
    id: ModelTurnId,
    revision: HistoryRevision,
    messages: Vec<StoredMessage>,
    tools: Vec<Value>,
    _lease: RunLease,
}
impl ModelTurn {
    /// Native completion identity, never a provider-controlled tool ID.
    pub fn id(&self) -> &ModelTurnId {
        &self.id
    }
    /// Captured actual run; services borrow this rather than admitting a sibling.
    pub fn run(&self) -> &RunHandle {
        &self.run
    }
    /// Child cancellation for this provider exchange; the IO task still owns
    /// the ticket until its sockets and pending delivery have actually joined.
    pub fn cancellation(&self) -> tokio_util::sync::CancellationToken {
        self.run.cancel_token()
    }
    /// Exact history revision captured before this exchange.
    pub fn history_revision(&self) -> HistoryRevision {
        self.revision
    }
    /// Immutable complete messages; partial deltas never appear here.
    pub fn messages(&self) -> &[StoredMessage] {
        &self.messages
    }
    /// Native model schema projection for this captured mode and adapter set.
    pub fn tools(&self) -> &[Value] {
        &self.tools
    }
    /// Build the canonical provider input on a bounded preparation worker.
    /// Existing native wire/tuning/auth/cache code transforms this body afterward.
    /// Opaque message blocks remain untouched; disabled tools omit both fields.
    pub fn canonical_payload(
        &self,
        model: &crate::api::ModelId,
        stream: bool,
    ) -> Result<Box<RawValue>, crate::api::ApiError> {
        #[derive(Serialize)]
        struct Payload<'a> {
            model: &'a crate::api::ModelId,
            messages: Vec<&'a Message>,
            #[serde(skip_serializing_if = "Option::is_none")]
            tools: Option<&'a [Value]>,
            #[serde(skip_serializing_if = "Option::is_none")]
            tool_choice: Option<&'static str>,
            stream: bool,
        }
        let live_error = |error| match error {
            CoreError::Deadline => crate::api::ApiError::RunDeadline,
            _ => crate::api::ApiError::Cancelled,
        };
        self.run.check_live().map_err(live_error)?;
        let enabled = !self.tools.is_empty();
        let payload = Payload {
            model,
            messages: self.messages.iter().map(StoredMessage::message).collect(),
            tools: enabled.then_some(self.tools.as_slice()),
            tool_choice: enabled.then_some("auto"),
            stream,
        };
        let raw = serde_json::value::to_raw_value(&payload)
            .map_err(|_| crate::api::ApiError::InvalidRequest)?;
        if raw.get().len() > limits::API_REQUEST_BYTES {
            return Err(crate::api::ApiError::Limit);
        }
        self.run.check_live().map_err(live_error)?;
        Ok(raw)
    }
    /// Complete only after native HTTP/SSE has produced a full validated turn.
    pub fn complete(
        self,
        actor: &mut ApplicationActor,
        reply: AssistantTurn,
    ) -> Result<AgentPhase, CoreError> {
        actor.complete_model_turn(&self, reply)
    }
    /// Report terminal transport failure after actual request drain.
    pub fn failed(self, actor: &mut ApplicationActor) -> Result<(), CoreError> {
        actor.check_model_turn(&self)?;
        actor.agent_mut(&self.run)?.phase = Phase::Terminal(AgentStop::Failed);
        Ok(())
    }
}

/// Typed dispatch refusal; no decision is inferred from a rendered error prefix.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolRefusal {
    /// Captured selection disabled tools.
    Disabled,
    /// No advertised native/editor capability can execute this tool.
    Unavailable,
    /// Captured operating mode forbids it.
    Mode,
    /// Completed argument object fails the trusted schema or byte bound.
    Arguments,
    /// User explicitly declined a repeated operation.
    UserRejected,
}
/// Dispatch readiness still requires concrete authorization at the shared gate.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "admission", content = "reason", rename_all = "snake_case")]
pub enum ToolAdmission {
    /// Still needs the shared native execution/approval gate.
    Ready,
    /// Third consecutive same canonical name and semantic argument object.
    Repetition,
    /// This exact committed call must receive a failure result.
    Refused(ToolRefusal),
}

/// One committed model invocation. This is dispatch correlation, never a grant.
/// Process/edit/editor execution must separately consume the shared native gate.
#[must_use = "Keep the tool ticket until actual effects and result commit have drained"]
pub struct AgentTool {
    run: RunHandle,
    id: ToolCallId,
    name: ToolName,
    arguments: Arc<RawValue>,
    route: Option<ToolRoute>,
    admission: ToolAdmission,
    _lease: RunLease,
}
impl AgentTool {
    /// Original foreground owner, shared by every actual child effect.
    pub fn run(&self) -> &RunHandle {
        &self.run
    }
    /// Native committed call identity shared by execution and history.
    pub fn id(&self) -> &ToolCallId {
        &self.id
    }
    /// Canonical tool name, or unchanged requested name for an unknown tool.
    pub fn name(&self) -> &ToolName {
        &self.name
    }
    /// Complete original argument object, never an SSE fragment.
    pub fn arguments(&self) -> &RawValue {
        &self.arguments
    }
    /// Trusted executor boundary; absent for a tool with no native definition.
    pub fn route(&self) -> Option<ToolRoute> {
        self.route
    }
    /// Dispatch decision, independent of concrete action approval.
    pub fn admission(&self) -> ToolAdmission {
        self.admission
    }
    /// A repeat confirmation only unlocks dispatch; mutation consent is still
    /// required at the shared gate, bound to the concrete captured action.
    pub fn decide_repetition(
        mut self,
        actor: &mut ApplicationActor,
        decision: UserDecision,
    ) -> Result<Self, CoreError> {
        actor.validate(&self.run)?;
        if self.admission != ToolAdmission::Repetition {
            return Err(CoreError::Rejected);
        }
        let machine = actor.agent_mut(&self.run)?;
        match &mut machine.phase {
            Phase::Tool { id, admission }
                if id == &self.id && *admission == ToolAdmission::Repetition =>
            {
                self.admission = match decision {
                    UserDecision::Approved => ToolAdmission::Ready,
                    UserDecision::Rejected => ToolAdmission::Refused(ToolRefusal::UserRejected),
                };
                *admission = self.admission;
                Ok(self)
            }
            _ => Err(CoreError::StaleOwner),
        }
    }
    /// Preserve an actual result even after owner cancellation. No new work is
    /// admitted until the native ledger and history agree on this completion.
    pub fn complete(
        self,
        actor: &mut ApplicationActor,
        outcome: ToolOutcome,
        text: &str,
    ) -> Result<MessageId, CoreError> {
        if self.admission != ToolAdmission::Ready && outcome == ToolOutcome::Ok {
            return Err(CoreError::Rejected);
        }
        let call = actor
            .owned(&self.run)?
            .calls
            .get(&self.id)
            .ok_or(CoreError::StaleOwner)?;
        if matches!(outcome, ToolOutcome::Ok | ToolOutcome::OutcomeUnknown) && !call.started {
            return Err(CoreError::Rejected);
        }
        match actor.call_steps_settled(&self.run, &self.id)? {
            Some(false) => return Err(CoreError::Busy),
            None if call.started && call.outcome.is_none() => return Err(CoreError::Busy),
            _ => {}
        }
        match &actor.agent(&self.run)?.phase {
            Phase::Tool { id, .. } if id == &self.id => {}
            _ => return Err(CoreError::StaleOwner),
        }
        let id = match actor.complete_history_call(&self.run, &self.id, outcome, text) {
            Err(CoreError::Limit | CoreError::History(crate::history::HistoryError::Limit)) => {
                let summary = format!(
                    "{}\n[Result text omitted: native history capacity exhausted.]",
                    outcome.summary()
                );
                actor.complete_history_call(&self.run, &self.id, outcome, &summary)?
            }
            result => result?,
        };
        let settled = actor
            .histories
            .get(self.run.scope().session_id())
            .ok_or(CoreError::StaleOwner)?
            .settled();
        actor.agent_mut(&self.run)?.phase = if settled { Phase::Ready } else { Phase::Tools };
        Ok(id)
    }
}

impl ApplicationActor {
    fn agent(&self, run: &RunHandle) -> Result<&AgentMachine, CoreError> {
        self.owned(run)?
            .agent
            .as_ref()
            .ok_or(CoreError::Unavailable)
    }
    fn agent_mut(&mut self, run: &RunHandle) -> Result<&mut AgentMachine, CoreError> {
        self.owned_mut(run)?
            .agent
            .as_mut()
            .ok_or(CoreError::Unavailable)
    }
    /// Bind the native machine to an existing foreground run. Prompt and
    /// initial state are committed together without yielding to another writer.
    pub fn start_agent(
        &mut self,
        run: &RunHandle,
        options: AgentOptions,
        prompt: Option<Message>,
    ) -> Result<(), CoreError> {
        self.validate(run)?;
        if run.scope().purpose() != RunPurpose::AgentTurn || self.owned(run)?.agent.is_some() {
            return Err(CoreError::Rejected);
        }
        if !run.drained() || !self.owned(run)?.calls.is_empty() {
            return Err(CoreError::Busy);
        }
        if options.editor_available.len() > limits::TOOL_DEFINITIONS {
            return Err(CoreError::Limit);
        }
        let mut names = HashSet::new();
        for name in &options.editor_available {
            let definition = run.tool_registry().resolve(name)?;
            if !names.insert(name)
                || definition.name() != name
                || !matches!(
                    definition.presentation().map(|p| p.route()),
                    Some(ToolRoute::Editor | ToolRoute::NativeEdit)
                )
            {
                return Err(CoreError::Rejected);
            }
        }
        let history = self.session_history(run.scope().session_id())?;
        if !history.settled() {
            return Err(CoreError::Busy);
        }
        if let Some(message) = &prompt {
            if message.role() != Role::User {
                return Err(CoreError::Rejected);
            }
        } else {
            let messages = history.snapshot();
            if !messages
                .iter()
                .any(|message| message.message().role() == Role::User)
                || messages
                    .last()
                    .is_none_or(|message| message.message().role() == Role::Assistant)
            {
                return Err(CoreError::Rejected);
            }
        }
        if let Some(message) = prompt {
            self.append_history(run, message)?;
        }
        self.owned_mut(run)?.agent = Some(AgentMachine {
            options,
            turns: ModelTurns::default(),
            phase: Phase::Ready,
            repeated: None,
        });
        Ok(())
    }
    /// Read an exact run's native phase without admitting work or touching IO.
    pub fn agent_phase(&self, run: &RunHandle) -> Result<AgentPhase, CoreError> {
        Ok(self.agent(run)?.phase.view())
    }
    /// Freeze one complete outbound history/schema snapshot. A second request
    /// cannot overtake the first, and partial stream deltas never enter history.
    pub fn begin_model_turn(&mut self, run: &RunHandle) -> Result<ModelTurn, CoreError> {
        self.validate(run)?;
        let machine = self.agent(run)?;
        if !matches!(machine.phase, Phase::Ready) {
            return Err(CoreError::Busy);
        }
        if machine.turns.0 >= machine.options.turn_limit.0 {
            return Err(CoreError::Limit);
        }
        let turns = ModelTurns(
            machine
                .turns
                .0
                .checked_add(1)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let tools = if machine.options.tools_enabled {
            run.tool_registry()
                .model_tools(run.settings().mode, &machine.options.editor_available)?
        } else {
            Vec::new()
        };
        let (revision, messages) = self.history_snapshot(run.scope().session_id())?;
        if !self.session_history(run.scope().session_id())?.settled() {
            return Err(CoreError::Busy);
        }
        let lease = run.lease()?;
        let id = ModelTurnId::new();
        let machine = self.agent_mut(run)?;
        machine.turns = turns;
        machine.phase = Phase::Model {
            id: id.clone(),
            revision,
        };
        Ok(ModelTurn {
            run: run.clone(),
            id,
            revision,
            messages,
            tools,
            _lease: lease,
        })
    }
    fn check_model_turn(&self, turn: &ModelTurn) -> Result<(), CoreError> {
        self.validate(&turn.run)?;
        match &self.agent(&turn.run)?.phase {
            Phase::Model { id, revision } if id == &turn.id && revision == &turn.revision => {}
            _ => return Err(CoreError::StaleOwner),
        }
        if self
            .session_history(turn.run.scope().session_id())?
            .revision()
            != turn.revision
        {
            return Err(CoreError::StaleOwner);
        }
        Ok(())
    }
    fn complete_model_turn(
        &mut self,
        turn: &ModelTurn,
        reply: AssistantTurn,
    ) -> Result<AgentPhase, CoreError> {
        self.check_model_turn(turn)?;
        let phase = match reply.finish() {
            Finish::Filtered => Phase::Terminal(AgentStop::ContentFiltered),
            Finish::Other => Phase::Terminal(AgentStop::ProviderStopped),
            Finish::Length => Phase::Continuation(ContinuationReason::Length),
            _ if !reply.message.calls().is_empty() => Phase::Tools,
            _ if reply.answer => Phase::Terminal(AgentStop::Answer),
            _ if reply.thought => Phase::Continuation(ContinuationReason::ThoughtOnly),
            _ => Phase::Continuation(ContinuationReason::Empty),
        };
        self.append_agent_message(&turn.run, reply.message)?;
        let machine = self.agent_mut(&turn.run)?;
        machine.phase = phase;
        Ok(machine.phase.view())
    }
    /// Continue a completed thought/empty/length turn with one native notice.
    /// The dispatcher obtains any required user decision before invoking this.
    pub fn continue_agent(
        &mut self,
        run: &RunHandle,
        expected: ContinuationReason,
    ) -> Result<(), CoreError> {
        self.validate(run)?;
        if !matches!(self.agent(run)?.phase, Phase::Continuation(reason) if reason == expected) {
            return Err(CoreError::StaleOwner);
        }
        let notice = match expected {
            ContinuationReason::ThoughtOnly => {
                "System Notice: Your previous turn contained only reasoning and no answer or tool call. Continue: write the answer or call a tool."
            }
            ContinuationReason::Empty => {
                "System Notice: You returned an empty response without calling any tools. Please inspect the code using the available tools and address the user query."
            }
            ContinuationReason::Length => "Continue from your previous response.",
        };
        let message: Message =
            serde_json::from_value(serde_json::json!({"role":"user", "content":notice}))
                .map_err(|_| CoreError::InvalidToolOutput)?;
        self.append_agent_message(run, message)?;
        self.agent_mut(run)?.phase = Phase::Ready;
        Ok(())
    }
    /// Explicitly extend a turn ceiling after a scoped UI decision. Existing
    /// spent turns remain charged and the absolute run deadline never changes.
    pub fn extend_agent_turns(
        &mut self,
        run: &RunHandle,
        limit: ModelTurnLimit,
    ) -> Result<(), CoreError> {
        self.validate(run)?;
        let machine = self.agent_mut(run)?;
        if !matches!(machine.phase, Phase::Ready)
            || machine.turns.0 < machine.options.turn_limit.0
            || limit.0 <= machine.options.turn_limit.0
        {
            return Err(CoreError::Rejected);
        }
        machine.options.turn_limit = limit;
        Ok(())
    }
    /// Correlate exactly one committed invocation, in provider batch order.
    /// Rejections become results for that call rather than a protocol gap.
    pub fn next_agent_tool(&mut self, run: &RunHandle) -> Result<AgentTool, CoreError> {
        self.validate(run)?;
        let machine = self.agent(run)?;
        if !matches!(machine.phase, Phase::Tools) {
            return Err(CoreError::Busy);
        }
        let pending = self
            .session_history(run.scope().session_id())?
            .pending_calls()?;
        let pending = pending.first().ok_or(CoreError::StaleOwner)?;
        let provider_id = pending.call.id().clone();
        let requested = pending.call.name().clone();
        let arguments: Arc<RawValue> = Arc::from(pending.call.arguments().to_owned());
        let mut name = requested.clone();
        let mut route = None;
        let mut admission = if machine.options.tools_enabled {
            ToolAdmission::Ready
        } else {
            ToolAdmission::Refused(ToolRefusal::Disabled)
        };
        let mut signature = None;
        if admission == ToolAdmission::Ready {
            match run.tool_registry().resolve(&requested) {
                Ok(definition) => {
                    name = definition.name().clone();
                    if let Some(metadata) = definition.presentation() {
                        route = Some(metadata.route());
                        if !definition.permits_mode(run.settings().mode) {
                            admission = ToolAdmission::Refused(ToolRefusal::Mode);
                        } else if matches!(
                            metadata.route(),
                            ToolRoute::Editor | ToolRoute::NativeEdit
                        ) && !machine.options.editor_available.contains(&name)
                        {
                            admission = ToolAdmission::Refused(ToolRefusal::Unavailable);
                        } else if metadata.route() == ToolRoute::Editor
                            && arguments.get().len() > limits::EDITOR_TOOL_ARGUMENT_BYTES
                        {
                            admission = ToolAdmission::Refused(ToolRefusal::Arguments);
                        } else {
                            let value: Value = serde_json::from_str(arguments.get())
                                .map_err(|_| CoreError::InvalidToolOutput)?;
                            if metadata.parameters().validate(&value).is_err() {
                                admission = ToolAdmission::Refused(ToolRefusal::Arguments);
                            } else {
                                let bytes = serde_json::to_vec(&(definition.name(), value))
                                    .map_err(|_| CoreError::InvalidToolOutput)?;
                                signature = Some(<[u8; 32]>::from(Sha256::digest(bytes)));
                            }
                        }
                    } else {
                        admission = ToolAdmission::Refused(ToolRefusal::Unavailable);
                    }
                }
                Err(CoreError::Unavailable) => {
                    admission = ToolAdmission::Refused(ToolRefusal::Unavailable)
                }
                Err(error) => return Err(error),
            }
        }
        let count = match (signature, &machine.repeated) {
            (Some(signature), Some(last)) if signature == last.signature => RepeatCount(
                last.count
                    .0
                    .saturating_add(1)
                    .min(limits::AGENT_REPETITIONS),
            ),
            _ => RepeatCount(1),
        };
        if admission == ToolAdmission::Ready && count.0 == limits::AGENT_REPETITIONS {
            admission = ToolAdmission::Repetition;
        }
        let lease = run.lease()?;
        let id = self.register_history_call(run, &provider_id, run.tool_registry())?;
        let machine = self.agent_mut(run)?;
        machine.repeated = signature.map(|signature| Repetition { signature, count });
        machine.phase = Phase::Tool {
            id: id.clone(),
            admission,
        };
        Ok(AgentTool {
            run: run.clone(),
            id,
            name,
            arguments,
            route,
            admission,
            _lease: lease,
        })
    }
}
