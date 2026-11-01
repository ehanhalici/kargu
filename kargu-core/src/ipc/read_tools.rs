//! One mailbox writer owns bounded read admission and completion publication.

use super::protocol::{Fault, RpcId};
use crate::{
    application::{
        RunHandle, ToolOutcome,
        agent::{AgentTool, ToolAdmission},
        host::{Host, ReadScope},
    },
    configuration::read::{ReadInput, ReadOutput},
    constants::{limits, protocol, timeouts},
    domain::{RequestScope, ToolName, ToolSafetyLevel},
    error::CoreError,
    workspace::{ReadResult, WorkspaceRead},
};
use serde_json::{Value, json, value::RawValue};
use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::task::JoinSet;
use tokio_util::sync::{CancellationToken, DropGuard};

pub(super) struct ReadDelivery {
    pub id: RpcId,
    pub call: AgentTool,
    pub outcome: ToolOutcome,
    pub text: String,
}

/// A detached native plan is bound to one model invocation, before editor IO.
pub(super) struct PreparedReadCall {
    scope: crate::application::RunScope,
    call_id: crate::domain::ToolCallId,
    input: WorkspaceRead,
}
impl PreparedReadCall {
    pub fn capture_file(call: &AgentTool) -> Result<Self, CoreError> {
        if call.name().as_str() != "read_file" || call.admission() != ToolAdmission::Ready {
            return Err(CoreError::Rejected);
        }
        Ok(Self {
            scope: call.run().scope().clone(),
            call_id: call.id().clone(),
            input: prepare_call(call.run(), call.name(), call.arguments())?,
        })
    }
    pub fn capture_request(&self) -> Result<Value, CoreError> {
        match &self.input {
            WorkspaceRead::ReadFile(input) => Ok(input.editor_capture()),
            _ => Err(CoreError::Rejected),
        }
    }
    pub fn with_editor_snapshot(
        self,
        snapshot: crate::workspace::file::EditorSnapshot,
    ) -> Result<Self, CoreError> {
        let WorkspaceRead::ReadFile(input) = self.input else {
            return Err(CoreError::Rejected);
        };
        Ok(Self {
            scope: self.scope,
            call_id: self.call_id,
            input: WorkspaceRead::ReadFile(input.with_editor_snapshot(snapshot)?),
        })
    }
}

struct PendingRead {
    scope: ReadOwner,
    cancel: CancellationToken,
    deadline: Instant,
    terminal: Option<CoreError>,
    edit: Option<crate::edit::prepare::PreparationId>,
    history: Option<crate::domain::HistoryUploadId>,
    call: Option<AgentTool>,
}

enum ReadOwner {
    Session(ReadScope),
    Connection(RequestScope),
    Catalog {
        connection: RequestScope,
        owner: ReadScope,
        revision: crate::domain::ConfigRevision,
    },
}
impl ReadOwner {
    fn is_live(&self, host: &Host) -> bool {
        match self {
            Self::Session(scope) => host.owns_read_scope(scope),
            Self::Connection(scope) => host.owns_connection_read(scope),
            Self::Catalog {
                connection,
                owner,
                revision,
            } => host.owns_connection_read(connection) && host.owns_model_refresh(owner, *revision),
        }
    }
}
enum ReadOperation {
    History(crate::history::HistoryWork),
    Workspace(WorkspaceRead),
    Configuration(ReadInput),
    Edit(Box<crate::edit::prepare::Work>),
    Rollback(crate::edit::prepare::RollbackWork),
    JournalRecovery(crate::edit::journal::RecoverInput),
    ModelCatalog(Box<ModelCatalogWork>),
}
enum ReadCompletion {
    History(Box<crate::history::History>),
    Workspace(ReadResult),
    Configuration(ReadOutput),
    Edit(Box<crate::edit::prepare::PreparationResult>),
    JournalRecovery(Box<crate::edit::journal::RecoveredJournal>),
    ModelCatalog(Box<ModelCatalogResult>),
}

pub(crate) struct ModelCatalogWork {
    pub owner: ReadScope,
    pub configuration_revision: crate::domain::ConfigRevision,
    pub provider: crate::providers::ApiProviderId,
    pub request: crate::api::HttpRequest,
    pub specs: crate::models::metadata::EffortSpecs,
}

#[derive(Clone)]
pub(crate) struct ModelCatalogResult {
    pub owner: ReadScope,
    pub configuration_revision: crate::domain::ConfigRevision,
    pub provider: crate::providers::ApiProviderId,
    pub catalog: crate::models::catalog::ModelCatalog,
    pub summaries: Vec<crate::models::store::ModelSummaryDto>,
    pub specs: crate::models::metadata::EffortSpecs,
}
impl ReadOperation {
    fn timeout(&self) -> Duration {
        match self {
            Self::Workspace(_) => timeouts::WORKSPACE_READ,
            Self::Configuration(input) => input.timeout(),
            Self::Edit(_) | Self::Rollback(_) => timeouts::WORKSPACE_READ,
            Self::JournalRecovery(_) => timeouts::EDIT_JOURNAL,
            Self::History(_) => timeouts::HISTORY_IMPORT,
            Self::ModelCatalog(_) => Duration::from_secs(15),
        }
    }
    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ReadCompletion, CoreError> {
        match self {
            Self::ModelCatalog(work) => tokio::runtime::Handle::current().block_on(async move {
                let snapshot =
                    crate::api::execute(work.request, |_| async { Ok(()) }, cancel.clone())
                        .await
                        .map_err(|error| match error {
                            crate::api::ApiError::Cancelled => CoreError::Cancelled,
                            crate::api::ApiError::Deadline
                            | crate::api::ApiError::FirstByteTimeout => CoreError::Deadline,
                            crate::api::ApiError::Limit => CoreError::Limit,
                            _ => CoreError::Unavailable,
                        })?;
                let source = snapshot.to_string();
                let catalog = crate::models::catalog::ModelCatalog::try_from(source.as_str())
                    .map_err(|_| CoreError::InvalidValue {
                        field: "catalog_shape",
                    })?;
                let summaries = crate::api::catalog::summaries(&catalog, &work.specs);
                Ok(ReadCompletion::ModelCatalog(Box::new(ModelCatalogResult {
                    owner: work.owner,
                    configuration_revision: work.configuration_revision,
                    provider: work.provider,
                    catalog,
                    summaries,
                    specs: work.specs,
                })))
            }),
            Self::History(work) => work
                .execute(cancel, deadline)
                .map(|history| ReadCompletion::History(Box::new(history))),
            Self::Rollback(input) => input
                .execute(cancel, deadline)
                .map(|value| ReadCompletion::Edit(Box::new(value))),
            Self::Edit(input) => input
                .execute(cancel, deadline)
                .map(|value| ReadCompletion::Edit(Box::new(value))),
            Self::Workspace(input) => input
                .execute(cancel, deadline)
                .map(ReadCompletion::Workspace),
            Self::Configuration(input) => input
                .execute(cancel, deadline)
                .map(ReadCompletion::Configuration),
            Self::JournalRecovery(input) => crate::edit::journal::recover(
                input.journal_directory,
                input.edit_id,
                cancel,
                deadline,
            )
            .map(|value| ReadCompletion::JournalRecovery(Box::new(value))),
        }
    }
}
impl ReadCompletion {
    fn into_value(self) -> Result<Value, CoreError> {
        match self {
            Self::Workspace(value) => serde_json::to_value(value).map_err(|_| CoreError::Limit),
            Self::Configuration(value) => Ok(value.into_editor_value()),
            Self::Edit(_) => Err(CoreError::CleanupFailed),
            Self::History(_) => Err(CoreError::CleanupFailed),
            Self::JournalRecovery(value) => Ok(value.into_json()),
            Self::ModelCatalog(value) => Ok(serde_json::json!({
                "status": "ok",
                "provider": value.provider.as_str(),
                "models": value.summaries,
                "cached": false
            })),
        }
    }
}

pub(super) enum ReadEvent {
    Message(Value),
    History {
        id: RpcId,
        scope: ReadScope,
        ticket: crate::domain::HistoryUploadId,
        result: Result<Box<crate::history::History>, CoreError>,
    },
    Edit {
        id: RpcId,
        scope: ReadScope,
        ticket: crate::edit::prepare::PreparationId,
        result: Result<Box<crate::edit::prepare::PreparationResult>, CoreError>,
    },
    ModelCatalog {
        id: RpcId,
        scope: RequestScope,
        result: Result<Box<ModelCatalogResult>, CoreError>,
    },
    Tool,
}
impl ReadEvent {
    pub(super) fn publish(self, host: &mut Host) -> Option<Value> {
        match self {
            Self::Message(value) => Some(value),
            Self::ModelCatalog { id, scope, result } => Some(match result {
                Ok(res) => {
                    if let Err(error) = host.update_provider_models(
                        &scope,
                        &res.owner,
                        res.configuration_revision,
                        res.provider.clone(),
                        res.catalog,
                        res.specs,
                    ) {
                        return Some(fault(error).response(Some(&id)));
                    }
                    super::protocol::success(
                        &id,
                        serde_json::json!({
                            "status": "ok",
                            "provider": res.provider.as_str(),
                            "models": res.summaries,
                            "cached": false
                        }),
                    )
                }
                Err(error) => fault(error).response(Some(&id)),
            }),
            Self::History {
                id,
                scope,
                ticket,
                result,
            } => Some(
                match host.finish_history_import(&scope, &ticket, result.map(|history| *history)) {
                    Ok(value) => super::protocol::success(&id, value),
                    Err(fault) => fault.response(Some(&id)),
                },
            ),
            Self::Edit {
                id,
                scope,
                ticket,
                result,
            } => Some(
                match host.finish_edit(&scope, &ticket, result.map(|prepared| *prepared)) {
                    Ok(value) => super::protocol::success(&id, value),
                    Err(fault) => fault.response(Some(&id)),
                },
            ),
            Self::Tool => None,
        }
    }
}

pub(super) struct ReadTools {
    requests: HashMap<RpcId, PendingRead>,
    completed: VecDeque<ReadDelivery>,
    workers: JoinSet<(RpcId, Result<ReadCompletion, CoreError>)>,
    root: CancellationToken,
    _cancel_on_drop: DropGuard,
}

impl Default for ReadTools {
    fn default() -> Self {
        let root = CancellationToken::new();
        Self {
            requests: HashMap::new(),
            completed: VecDeque::new(),
            workers: JoinSet::new(),
            _cancel_on_drop: root.clone().drop_guard(),
            root,
        }
    }
}

impl ReadTools {
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.requests.values().any(|pending| match &pending.scope {
            ReadOwner::Session(scope) | ReadOwner::Catalog { owner: scope, .. } => {
                &scope.application_id == id
            }
            ReadOwner::Connection(_) => false,
        }) || self
            .completed
            .iter()
            .any(|delivery| delivery.call.run().scope().application_id() == id)
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.requests.contains_key(id) || self.completed.iter().any(|delivery| &delivery.id == id)
    }
    pub fn is_empty(&self) -> bool {
        self.requests.is_empty() && self.completed.is_empty()
    }
    pub fn has_workers(&self) -> bool {
        !self.requests.is_empty()
    }
    pub fn has_completed(&self) -> bool {
        !self.completed.is_empty()
    }
    pub fn take_call(&mut self) -> Option<ReadDelivery> {
        self.completed.pop_front()
    }

    pub fn start_call(
        &mut self,
        host: &mut Host,
        id: RpcId,
        call: AgentTool,
    ) -> Result<(), Box<(CoreError, AgentTool)>> {
        self.start_prepared_call(host, id, call, None)
    }

    pub fn start_prepared_call(
        &mut self,
        host: &mut Host,
        id: RpcId,
        call: AgentTool,
        prepared: Option<PreparedReadCall>,
    ) -> Result<(), Box<(CoreError, AgentTool)>> {
        if self.root.is_cancelled() {
            return Err(Box::new((CoreError::Cancelled, call)));
        }
        if self.contains(&id)
            || self.requests.len().saturating_add(self.completed.len()) >= limits::READ_WORKERS
        {
            return Err(Box::new((CoreError::Limit, call)));
        }
        if call.admission() != ToolAdmission::Ready
            || call.route() != Some(crate::security::ToolRoute::NativeRead)
        {
            return Err(Box::new((CoreError::Rejected, call)));
        }
        let scope = ReadScope {
            application_id: call.run().scope().application_id().clone(),
            session_id: call.run().scope().session_id().clone(),
        };
        if !host.owns_read_scope(&scope) {
            return Err(Box::new((CoreError::StaleOwner, call)));
        }
        if let Err(error) = call.run().check_live() {
            return Err(Box::new((error, call)));
        }
        let actor = match host.actor_mut(&scope) {
            Ok(actor) => actor,
            Err(error) => return Err(Box::new((error, call))),
        };
        if let Err(error) = actor.reserve_call(
            call.run(),
            call.id().clone(),
            call.name().clone(),
            ToolSafetyLevel::SafeReadOnly,
        ) {
            return Err(Box::new((error, call)));
        }
        let prepared = match prepared {
            Some(prepared)
                if prepared.scope == *call.run().scope() && prepared.call_id == *call.id() =>
            {
                Ok(prepared.input)
            }
            Some(_) => Err(CoreError::StaleOwner),
            None => prepare_call(call.run(), call.name(), call.arguments()),
        };
        let input = match prepared {
            Ok(input) => ReadOperation::Workspace(input),
            Err(error) => {
                let (outcome, text) = read_failure(error);
                self.completed.push_back(ReadDelivery {
                    id,
                    call,
                    outcome,
                    text,
                });
                return Ok(());
            }
        };
        let deadline = match Instant::now().checked_add(input.timeout()) {
            Some(deadline) => call
                .run()
                .deadline()
                .cap(tokio::time::Instant::from_std(deadline))
                .into_std(),
            None => return Err(Box::new((CoreError::ArithmeticOverflow, call))),
        };
        if let Err(error) = actor.mark_started(call.run(), call.id()) {
            return Err(Box::new((error, call)));
        }
        let cancel = call.run().cancel_token();
        let workspace = call.run().settings().workspace.clone();
        self.requests.insert(
            id.clone(),
            PendingRead {
                scope: ReadOwner::Session(scope),
                cancel: cancel.clone(),
                deadline,
                terminal: None,
                edit: None,
                history: None,
                call: Some(call),
            },
        );
        self.workers.spawn_blocking(move || {
            let result = (|| {
                crate::security::file::checkpoint(&cancel, deadline)?;
                workspace.revalidate()?;
                let result = input.execute(&cancel, deadline)?;
                workspace.revalidate()?;
                crate::security::file::checkpoint(&cancel, deadline)?;
                Ok(result)
            })();
            (id, result)
        });
        Ok(())
    }

    pub fn start(
        &mut self,
        id: RpcId,
        scope: ReadScope,
        input: WorkspaceRead,
    ) -> Result<(), Fault> {
        self.start_owned(
            id,
            ReadOwner::Session(scope),
            ReadOperation::Workspace(input),
        )
    }

    pub fn start_configuration(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        input: ReadInput,
    ) -> Result<(), Fault> {
        self.start_owned(
            id,
            ReadOwner::Connection(scope),
            ReadOperation::Configuration(input),
        )
    }

    pub fn start_model_refresh(
        &mut self,
        id: RpcId,
        scope: RequestScope,
        input: ModelCatalogWork,
    ) -> Result<(), Fault> {
        let owner = ReadOwner::Catalog {
            connection: scope,
            owner: input.owner.clone(),
            revision: input.configuration_revision,
        };
        self.start_owned(id, owner, ReadOperation::ModelCatalog(Box::new(input)))
    }

    pub fn start_edit(
        &mut self,
        id: RpcId,
        scope: ReadScope,
        input: crate::edit::prepare::Work,
    ) -> Result<(), Fault> {
        self.start_owned(
            id,
            ReadOwner::Session(scope),
            ReadOperation::Edit(Box::new(input)),
        )
    }

    pub fn start_rollback(
        &mut self,
        id: RpcId,
        scope: ReadScope,
        input: crate::edit::prepare::RollbackWork,
    ) -> Result<(), Fault> {
        self.start_owned(
            id,
            ReadOwner::Session(scope),
            ReadOperation::Rollback(input),
        )
    }

    pub fn start_journal_recovery(
        &mut self,
        id: RpcId,
        scope: ReadScope,
        input: crate::edit::journal::RecoverInput,
    ) -> Result<(), Fault> {
        self.start_owned(
            id,
            ReadOwner::Session(scope),
            ReadOperation::JournalRecovery(input),
        )
    }

    pub fn start_history_import(
        &mut self,
        id: RpcId,
        scope: ReadScope,
        input: crate::history::HistoryWork,
    ) -> Result<(), Fault> {
        self.start_owned(id, ReadOwner::Session(scope), ReadOperation::History(input))
    }

    fn start_owned(
        &mut self,
        id: RpcId,
        scope: ReadOwner,
        input: ReadOperation,
    ) -> Result<(), Fault> {
        if self.root.is_cancelled() {
            return Err(fault(CoreError::Cancelled));
        }
        if self.contains(&id)
            || self.requests.len().saturating_add(self.completed.len()) >= limits::READ_WORKERS
        {
            return Err(fault(CoreError::Limit));
        }
        let cancel = match &input {
            ReadOperation::Edit(work) => work
                .cancellation()
                .unwrap_or_else(|| self.root.child_token()),
            _ => self.root.child_token(),
        };
        let deadline = Instant::now()
            .checked_add(input.timeout())
            .ok_or_else(|| fault(CoreError::ArithmeticOverflow))?;
        let edit = match &input {
            ReadOperation::Edit(work) => Some(work.id.clone()),
            ReadOperation::Rollback(work) => Some(work.id.clone()),
            _ => None,
        };
        let history = match &input {
            ReadOperation::History(work) => Some(work.id.clone()),
            _ => None,
        };
        self.requests.insert(
            id.clone(),
            PendingRead {
                scope,
                cancel: cancel.clone(),
                deadline,
                terminal: None,
                edit,
                history,
                call: None,
            },
        );
        self.workers.spawn_blocking(move || {
            let result = input.execute(&cancel, deadline);
            (id, result)
        });
        Ok(())
    }

    pub fn cancel(&mut self, id: &RpcId) {
        if let Some(request) = self.requests.get_mut(id) {
            request.terminal = Some(CoreError::Cancelled);
            request.cancel.cancel();
        }
    }

    pub fn sweep(&mut self, host: &Host) {
        for request in self.requests.values_mut() {
            if request.terminal.is_none() {
                if !request.scope.is_live(host) {
                    request.terminal = Some(CoreError::StaleOwner);
                } else if let Some(call) = &request.call
                    && let Err(error) = call.run().check_live()
                {
                    request.terminal = Some(error);
                } else if let (ReadOwner::Session(scope), Some(ticket)) =
                    (&request.scope, &request.edit)
                    && !host.can_publish_edit(scope, ticket)
                {
                    request.terminal = Some(CoreError::Cancelled);
                } else if Instant::now() >= request.deadline {
                    request.terminal = Some(CoreError::Deadline);
                }
                if request.terminal.is_none()
                    && let (ReadOwner::Session(scope), Some(ticket)) =
                        (&request.scope, &request.history)
                    && !host.can_publish_history(scope, ticket)
                {
                    request.terminal = Some(CoreError::Cancelled);
                }
                if request.terminal.is_some() {
                    request.cancel.cancel();
                }
            }
        }
    }

    pub fn cancel_all(&mut self) {
        self.root.cancel();
        for request in self.requests.values_mut() {
            request.terminal = Some(CoreError::Cancelled);
            request.cancel.cancel();
        }
    }

    // The select! caller is the only writer. No I/O worker holds a Host reference.
    pub async fn next(&mut self, host: &Host) -> Option<Result<ReadEvent, CoreError>> {
        let joined = self.workers.join_next().await?;
        let Ok((id, result)) = joined else {
            return Some(Err(CoreError::CleanupFailed));
        };
        let Some(request) = self.requests.remove(&id) else {
            return Some(Err(CoreError::CleanupFailed));
        };
        let result = if let Some(error) = request.terminal {
            Err(error)
        } else if !request.scope.is_live(host) {
            Err(CoreError::StaleOwner)
        } else if let Some(call) = &request.call
            && let Err(error) = call.run().check_live()
        {
            Err(error)
        } else if Instant::now() >= request.deadline {
            Err(CoreError::Deadline)
        } else {
            result
        };
        if let Some(call) = request.call {
            let (outcome, text) = match result {
                Ok(ReadCompletion::Workspace(read)) => match read.into_tool_output() {
                    Ok(output) => output,
                    Err(error) => read_failure(error),
                },
                Ok(_) => read_failure(CoreError::CleanupFailed),
                Err(error) => read_failure(error),
            };
            self.completed.push_back(ReadDelivery {
                id,
                call,
                outcome,
                text,
            });
            return Some(Ok(ReadEvent::Tool));
        }
        if let Some(ticket) = request.history {
            let ReadOwner::Session(scope) = request.scope else {
                return Some(Err(CoreError::CleanupFailed));
            };
            let result = result.and_then(|completion| match completion {
                ReadCompletion::History(history) => Ok(history),
                _ => Err(CoreError::CleanupFailed),
            });
            return Some(Ok(ReadEvent::History {
                id,
                scope,
                ticket,
                result,
            }));
        }
        if let (ReadOwner::Session(scope), Some(ticket)) = (&request.scope, request.edit) {
            let result = result.and_then(|completion| match completion {
                ReadCompletion::Edit(prepared) => Ok(prepared),
                _ => Err(CoreError::CleanupFailed),
            });
            return Some(Ok(ReadEvent::Edit {
                id,
                scope: scope.clone(),
                ticket,
                result,
            }));
        }
        if let (
            ReadOwner::Catalog {
                connection: scope, ..
            },
            Ok(ReadCompletion::ModelCatalog(res)),
        ) = (&request.scope, &result)
        {
            return Some(Ok(ReadEvent::ModelCatalog {
                id,
                scope: scope.clone(),
                result: Ok(res.clone()),
            }));
        }
        Some(Ok(ReadEvent::Message(match result {
            Ok(result) => match result.into_value() {
                Ok(value) => super::protocol::success(&id, value),
                Err(_) => fault(CoreError::Limit).response(Some(&id)),
            },
            Err(error) => fault(error).response(Some(&id)),
        })))
    }
    #[cfg(test)]
    async fn next_message(&mut self, host: &Host) -> Option<Result<Value, CoreError>> {
        self.next(host).await.map(|result| {
            result.and_then(|event| match event {
                ReadEvent::Message(value) => Ok(value),
                ReadEvent::Edit { .. }
                | ReadEvent::History { .. }
                | ReadEvent::ModelCatalog { .. }
                | ReadEvent::Tool => Err(CoreError::CleanupFailed),
            })
        })
    }
}

fn default_skip_directories() -> Vec<&'static str> {
    vec![
        ".git",
        "node_modules",
        ".venv",
        "__pycache__",
        ".direnv",
        "dist",
        "build",
        "target",
        ".next",
        "vendor",
        "out",
        ".cache",
        ".cargo",
    ]
}

fn default_user_skill_root() -> Option<PathBuf> {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        let base = PathBuf::from(xdg);
        if base.is_absolute() {
            return Some(base.join("kargu/skills"));
        }
    }
    let home = std::env::var_os("HOME").filter(|v| !v.is_empty())?;
    let base = PathBuf::from(home);
    base.is_absolute()
        .then(|| base.join(".config/kargu/skills"))
}

fn string_arg(args: &Value, keys: &[&str]) -> Result<Option<String>, CoreError> {
    let mut found: Option<String> = None;
    for key in keys {
        let Some(raw) = args.get(*key) else {
            continue;
        };
        if raw.is_null() {
            continue;
        }
        let text = raw.as_str().ok_or(CoreError::InvalidValue {
            field: "NativeReadArgument",
        })?;
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Err(CoreError::InvalidValue {
                field: "NativeReadArgument",
            });
        }
        if let Some(existing) = &found
            && existing != trimmed
        {
            return Err(CoreError::InvalidValue {
                field: "ConflictingReadAliases",
            });
        }
        found = Some(trimmed.to_owned());
    }
    Ok(found)
}

fn integer_arg(args: &Value, keys: &[&str]) -> Result<Option<i64>, CoreError> {
    let mut found: Option<i64> = None;
    for key in keys {
        let Some(raw) = args.get(*key) else {
            continue;
        };
        let value = raw.as_i64().ok_or(CoreError::InvalidValue {
            field: "LineWindow",
        })?;
        if let Some(existing) = found
            && existing != value
        {
            return Err(CoreError::InvalidValue {
                field: "ConflictingLineWindow",
            });
        }
        found = Some(value);
    }
    Ok(found)
}

fn prepare_call(
    run: &RunHandle,
    name: &ToolName,
    arguments: &RawValue,
) -> Result<WorkspaceRead, CoreError> {
    run.check_live()?;
    let args: Value =
        serde_json::from_str(arguments.get()).map_err(|_| CoreError::InvalidToolOutput)?;
    let root = run.settings().workspace.path();
    match name.as_str() {
        "find_files" => {
            let pattern = string_arg(&args, &["pattern"])?.ok_or(CoreError::InvalidValue {
                field: "FindFilesPattern",
            })?;
            let path =
                string_arg(&args, &["path", "file_path", "filePath"])?.filter(|value| value != ".");
            if let Some(path) = &path {
                crate::workspace::command::validate_path(Path::new(path))?;
            }
            let input: crate::workspace::search::FindFilesInput = serde_json::from_value(json!({
                "root": root,
                "path": path,
                "pattern": pattern,
                "skip_directories": default_skip_directories(),
                "max_files": 2000,
                "max_directories": 2000,
            }))
            .map_err(|_| CoreError::InvalidValue {
                field: "FindFilesInput",
            })?;
            Ok(WorkspaceRead::FindFiles(input))
        }
        "read_file" => {
            let raw_path = string_arg(&args, &["file_path", "path", "filePath"])?
                .ok_or(CoreError::InvalidValue { field: "FilePath" })?;
            let requested = Path::new(&raw_path);
            crate::workspace::command::validate_path(requested)?;
            let relative = if requested.is_absolute() {
                requested
                    .strip_prefix(root)
                    .map_err(|_| CoreError::Rejected)?
            } else {
                requested.strip_prefix(".").unwrap_or(requested)
            };
            let display =
                relative
                    .to_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(CoreError::InvalidValue {
                        field: "FileDisplayPath",
                    })?;
            let from_line = integer_arg(&args, &["from_line", "fromLine"])?;
            let to_line = integer_arg(&args, &["to_line", "toLine"])?;
            let limit = integer_arg(&args, &["limit"])?;
            let offset = integer_arg(&args, &["offset"])?;
            if from_line.is_some_and(|v| v < 1)
                || to_line.is_some_and(|v| v < 1)
                || limit.is_some_and(|v| v < 1)
            {
                return Err(CoreError::InvalidValue {
                    field: "LineWindow",
                });
            }
            let alias = match offset {
                None => None,
                Some(0) => Some(1),
                Some(value) if value > 0 => Some(value),
                Some(_) => {
                    return Err(CoreError::InvalidValue {
                        field: "LineWindow",
                    });
                }
            };
            if let (Some(from), Some(alias)) = (from_line, alias)
                && from != alias
            {
                return Err(CoreError::InvalidValue {
                    field: "LineWindow",
                });
            }
            let from = from_line.or(alias).unwrap_or(1);
            let last = match limit {
                Some(limit) => Some(
                    from.checked_add(limit)
                        .and_then(|sum| sum.checked_sub(1))
                        .ok_or(CoreError::ArithmeticOverflow)?,
                ),
                None => None,
            };
            let to = match (last, to_line) {
                (Some(last), Some(to)) => Some(last.min(to)),
                (Some(last), None) => Some(last),
                (None, to) => to,
            };
            if to.is_some_and(|to| to < from) {
                return Err(CoreError::InvalidValue {
                    field: "LineWindow",
                });
            }
            let input: crate::workspace::file::ReadFileInput = serde_json::from_value(json!({
                "display_path": display,
                "window": {
                    "from": from,
                    "to": to,
                },
                "max_bytes": 16 * 1024 * 1024,
                "scan_chars": 16 * 1024 * 1024,
                "output_chars": 15_000,
                "source": {
                    "kind": "disk",
                    "root": root,
                    "path": display,
                },
            }))
            .map_err(|_| CoreError::InvalidValue {
                field: "ReadFileInput",
            })?;
            Ok(WorkspaceRead::ReadFile(input))
        }
        "skill" => {
            let skill_name = string_arg(&args, &["name"])?
                .ok_or(CoreError::InvalidValue { field: "SkillName" })?;
            let input: crate::workspace::skills::SkillInput = serde_json::from_value(json!({
                "root": root,
                "user_root": default_user_skill_root(),
                "skip_directories": default_skip_directories(),
                "max_directories": 2000,
                "max_file_bytes": 262_144,
                "body_chars": 12_000,
                "query": {
                    "operation": "load",
                    "name": skill_name,
                },
            }))
            .map_err(|_| CoreError::InvalidValue {
                field: "SkillInput",
            })?;
            Ok(WorkspaceRead::Skills(input))
        }
        "webfetch" => {
            let url = string_arg(&args, &["url"])?.ok_or(CoreError::InvalidValue {
                field: "WebfetchUrl",
            })?;
            let input: crate::workspace::webfetch::FetchInput = serde_json::from_value(json!({
                "url": url,
                "timeout_ms": 20_000,
                "resolve_timeout_ms": 5_000,
                "max_chars": 50_000,
            }))
            .map_err(|_| CoreError::InvalidValue {
                field: "FetchInput",
            })?;
            Ok(WorkspaceRead::Webfetch(input))
        }
        _ => Err(CoreError::Unavailable),
    }
}

fn read_failure(error: CoreError) -> (ToolOutcome, String) {
    let outcome = match error {
        CoreError::Cancelled | CoreError::StaleOwner => ToolOutcome::Cancelled,
        CoreError::Deadline => ToolOutcome::Timeout,
        CoreError::Rejected | CoreError::WorkspaceChanged | CoreError::ConfigurationChanged => {
            ToolOutcome::Rejected
        }
        _ => ToolOutcome::Failed,
    };
    let text = match outcome {
        ToolOutcome::Cancelled | ToolOutcome::Timeout => outcome.summary().to_owned(),
        _ => format!("ERROR: {}", fault(error).message),
    };
    (outcome, text)
}

fn fault(error: CoreError) -> Fault {
    use protocol::error_codes as codes;
    let (code, message, status) = match error {
        CoreError::InvalidValue { .. } => (
            codes::INVALID_PARAMS,
            "Invalid read arguments",
            "invalid_params",
        ),
        CoreError::Rejected => (
            codes::REJECTED,
            "Read path is outside its grant or unsupported",
            "rejected",
        ),
        CoreError::StaleOwner => (
            codes::STALE_OWNER,
            "Read owner is no longer live",
            "stale_owner",
        ),
        CoreError::Cancelled => (codes::CANCELLED, "Read cancelled", "cancelled"),
        CoreError::Deadline => (codes::TIMEOUT, "Read deadline exceeded", "timeout"),
        CoreError::WorkspaceChanged => (
            codes::WORKSPACE_CHANGED,
            "Read workspace changed",
            "workspace_changed",
        ),
        CoreError::ConfigurationChanged => (
            codes::WORKSPACE_CHANGED,
            "Configuration file changed",
            "configuration_changed",
        ),
        CoreError::Io(_) => (codes::IO, "Read filesystem operation failed", "io_error"),
        CoreError::Unavailable => (
            codes::METHOD_NOT_FOUND,
            "Native read transport or resolver unavailable",
            "unavailable",
        ),
        CoreError::InvalidToolOutput => (
            codes::INVALID_STATE,
            "Invalid native read response",
            "invalid_output",
        ),
        _ => (
            codes::RESOURCE_LIMIT,
            "Read resource limit reached",
            "resource_limit",
        ),
    };
    Fault {
        code,
        message,
        status,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::search::FindFilesInput;
    use serde_json::json;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn owner() -> Result<(Host, ReadScope), Box<dyn std::error::Error>> {
        let mut host = Host::new();
        host.dispatch(
            "initialize",
            json!({"protocol_major":1,"protocol_minor":0,
            "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),
            true,
        )
        .result
        .map_err(|_| "initialize failed")?;
        host.dispatch("initialized", json!({}), false)
            .result
            .map_err(|_| "initialized failed")?;
        let app = host
            .dispatch("application/create", json!({}), true)
            .result
            .map_err(|_| "application failed")?;
        let session = host
            .dispatch("session/create", app, true)
            .result
            .map_err(|_| "session failed")?;
        Ok((host, serde_json::from_value(session)?))
    }

    fn arguments(root: &std::path::Path) -> WorkspaceRead {
        WorkspaceRead::FindFiles(FindFilesInput {
            root: root.to_owned(),
            path: None,
            pattern: "*.el".into(),
            skip_directories: vec![],
            max_files: 2000,
            max_directories: 2000,
        })
    }

    #[tokio::test]
    async fn edit_workers_hold_shared_capacity_and_staging_until_actual_join() -> TestResult {
        let root = tempfile::tempdir()?;
        std::fs::write(root.path().join("source"), "before")?;
        for terminal in ["cancelled", "stale_owner", "timeout"] {
            let (mut host, scope) = owner()?;
            let mut tools = ReadTools::default();
            let origin = "editor_source_12345678-1234-4234-8234-123456789abc";
            let request = |arguments: Value| {
                json!({"scope": {"application_id":scope.application_id,
                "session_id":scope.session_id}, "arguments":arguments})
            };
            let begin = || {
                request(json!({"origin_id":origin,"root":root.path(),"mode":"agent",
                "intent":{"kind":"write","path":"source","new_bytes":0},"live":null,
                "config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"save"}))
            };
            let id = host
                .dispatch("edit/begin", begin(), true)
                .result
                .map_err(|_| "begin")?["preparation_id"]
                .clone();
            let ticket = request(json!({"origin_id":origin,"preparation_id":id}));
            let (_, work) = host
                .prepare_edit(ticket.clone(), false)
                .map_err(|_| "prepare")?;
            let crate::edit::prepare::PrepareWork::Read(work) = work else {
                return Err("expected file work".into());
            };
            tools
                .start_edit(RpcId::Integer(0), scope.clone(), work)
                .map_err(|_| "start")?;
            for n in 1..limits::READ_WORKERS {
                tools
                    .start(
                        RpcId::String(n.to_string()),
                        scope.clone(),
                        arguments(root.path()),
                    )
                    .map_err(|_| "start read")?;
            }
            if terminal == "cancelled" {
                host.dispatch("edit/abort", ticket, true)
                    .result
                    .map_err(|_| "abort")?;
                // A revoked worker still owns one of the two staging records.
                assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
                assert!(host.dispatch("edit/begin", begin(), true).result.is_err());
            } else if terminal == "timeout" {
                tools
                    .requests
                    .get_mut(&RpcId::Integer(0))
                    .ok_or("pending")?
                    .deadline = Instant::now();
            } else {
                host.dispatch(
                    "session/close",
                    json!({"application_id":scope.application_id,"session_id":scope.session_id}),
                    true,
                )
                .result
                .map_err(|_| "close")?;
            }
            tools.sweep(&host);
            assert!(
                tools
                    .start(RpcId::Integer(99), scope.clone(), arguments(root.path()))
                    .is_err()
            );
            let mut edit_seen = false;
            while let Some(event) = tools.next(&host).await {
                let reply = event?.publish(&mut host).ok_or("missing reply")?;
                if reply["id"] == 0 {
                    assert_eq!(reply["error"]["data"]["status"], terminal, "{reply}");
                    edit_seen = true;
                }
            }
            assert!(edit_seen);
            if terminal == "cancelled" {
                assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
            }
            assert_eq!(
                std::fs::read_to_string(root.path().join("source"))?,
                "before"
            );
        }
        Ok(())
    }

    #[tokio::test]
    async fn skill_workers_share_capacity_and_cannot_publish_after_revocation() -> TestResult {
        let root = tempfile::tempdir()?;
        std::fs::create_dir_all(root.path().join("skills/test"))?;
        std::fs::write(root.path().join("skills/test/SKILL.md"), "instructions")?;
        for ending in ["cancelled", "timeout", "stale_owner"] {
            let (mut host, scope) = owner()?;
            let mut tools = ReadTools::default();
            for id in 0..4 {
                let input = serde_json::from_value(json!({"root":root.path(),"user_root":null,
                    "skip_directories":[],"max_directories":2000,"max_file_bytes":262144,
                    "body_chars":12000,"query":{"operation":"catalog"}}))?;
                tools
                    .start(
                        RpcId::Integer(id),
                        scope.clone(),
                        WorkspaceRead::Skills(input),
                    )
                    .map_err(|_| "skill admission")?;
            }
            assert!(
                tools
                    .start(RpcId::Integer(4), scope.clone(), arguments(root.path()))
                    .is_err()
            );
            if ending == "cancelled" {
                for id in 0..4 {
                    tools.cancel(&RpcId::Integer(id));
                }
            } else if ending == "timeout" {
                for pending in tools.requests.values_mut() {
                    pending.deadline = Instant::now();
                }
            } else {
                host.dispatch(
                    "session/close",
                    json!({"application_id":scope.application_id,
                    "session_id":scope.session_id}),
                    true,
                )
                .result
                .map_err(|_| "close")?;
            }
            tools.sweep(&host);
            // Signal is not drain: admission stays occupied until actual join.
            assert!(
                tools
                    .start(RpcId::Integer(4), scope, arguments(root.path()))
                    .is_err()
            );
            let mut count = 0usize;
            while let Some(reply) = tools.next_message(&host).await {
                assert_eq!(reply?["error"]["data"]["status"], ending);
                count = count.saturating_add(1);
            }
            assert_eq!(count, 4);
            assert!(tools.is_empty());
        }
        Ok(())
    }

    #[tokio::test]
    async fn file_reads_retain_shared_worker_capacity_until_cancelled_completion_is_joined()
    -> TestResult {
        let root = tempfile::tempdir()?;
        std::fs::write(root.path().join("source"), "live source\n")?;
        let (host, scope) = owner()?;
        let mut tools = ReadTools::default();
        let arguments = || -> Result<WorkspaceRead, serde_json::Error> {
            serde_json::from_value(
                json!({"display_path":"source","window":{"from":1,"to":null},
                "max_bytes":65536,"scan_chars":65536,"output_chars":15000,
                "source":{"kind":"disk","root":root.path(),"path":"source"}}),
            )
            .map(WorkspaceRead::ReadFile)
        };
        for id in 0..4 {
            tools
                .start(RpcId::Integer(id), scope.clone(), arguments()?)
                .map_err(|_| "admission")?;
        }
        tools.cancel(&RpcId::Integer(0));
        assert!(
            tools
                .start(RpcId::Integer(4), scope.clone(), arguments()?)
                .is_err()
        );
        let mut seen = std::collections::HashSet::new();
        while let Some(reply) = tools.next_message(&host).await {
            let reply = reply?;
            assert!(seen.insert(reply["id"].as_i64().ok_or("id")?));
            if reply["id"] == 0 {
                assert_eq!(reply["error"]["data"]["status"], "cancelled");
            } else {
                assert!(
                    reply["result"]["text"]
                        .as_str()
                        .ok_or("text")?
                        .contains("1 | live source")
                );
            }
        }
        assert_eq!(seen.len(), 4);
        tools
            .start(RpcId::Integer(4), scope, arguments()?)
            .map_err(|_| "readmission")?;
        assert!(
            tools
                .next_message(&host)
                .await
                .ok_or("completion")??
                .get("result")
                .is_some()
        );
        Ok(())
    }

    #[tokio::test]
    async fn configuration_shares_capacity_and_revokes_late_results_before_publication()
    -> TestResult {
        let root = tempfile::tempdir()?;
        let path = root.path().join("config");
        std::fs::write(&path, "provider='private'")?;
        for ending in ["cancelled", "timeout", "stale_owner"] {
            let (mut host, workspace_scope) = owner()?;
            let scope = host.request_scope()?;
            let mut tools = ReadTools::default();
            for n in 0..limits::READ_WORKERS {
                let input = serde_json::from_value(
                    json!({"paths":[path], "generation":1, "timeout_ms":5000}),
                )?;
                tools
                    .start_configuration(RpcId::String(n.to_string()), scope.clone(), input)
                    .map_err(|_| "start failed")?;
            }
            assert!(!tools.owns_application(&workspace_scope.application_id));
            assert!(
                tools
                    .start(RpcId::Integer(9), workspace_scope, arguments(root.path()))
                    .is_err()
            );
            for pending in tools.requests.values_mut() {
                match ending {
                    "cancelled" => {
                        pending.terminal = Some(CoreError::Cancelled);
                        pending.cancel.cancel();
                    }
                    "timeout" => pending.deadline = Instant::now(),
                    _ => {}
                }
            }
            if ending == "stale_owner" {
                host.dispatch("shutdown", json!({}), true)
                    .result
                    .map_err(|_| "shutdown failed")?;
            }
            tools.sweep(&host);
            assert_eq!(tools.requests.len(), limits::READ_WORKERS);
            while let Some(reply) = tools.next_message(&host).await {
                assert_eq!(reply?["error"]["data"]["status"], ending);
            }
            assert!(tools.is_empty());
        }
        Ok(())
    }

    #[tokio::test]
    async fn discovery_capacity_and_cancel_are_request_scoped() -> TestResult {
        let root = tempfile::tempdir()?;
        let (host, scope) = owner()?;
        let mut tools = ReadTools::default();
        for n in 0..4 {
            let input = arguments(root.path());
            tools
                .start(RpcId::Integer(n), scope.clone(), input)
                .map_err(|_| "start failed")?;
        }
        tools.cancel(&RpcId::Integer(1));
        assert!(
            tools
                .start(RpcId::Integer(4), scope, arguments(root.path()))
                .is_err()
        );
        let mut completed = 0_usize;
        while let Some(reply) = tools.next_message(&host).await {
            let reply = reply?;
            if reply["id"] == 1 {
                assert_eq!(reply["error"]["data"]["status"], "cancelled");
            } else {
                assert!(reply.get("result").is_some());
            }
            completed = completed.saturating_add(1);
        }
        assert_eq!(completed, 4);
        assert!(tools.is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn cancel_retains_capacity_until_collection_and_completion_is_take_once() -> TestResult {
        let root = tempfile::tempdir()?;
        let (host, scope) = owner()?;
        let mut tools = ReadTools::default();
        for n in 0..4 {
            tools
                .start(RpcId::Integer(n), scope.clone(), arguments(root.path()))
                .map_err(|_| "start failed")?;
        }
        tools.cancel(&RpcId::Integer(0));
        assert!(tools.contains(&RpcId::Integer(0)));
        assert!(
            tools
                .start(RpcId::Integer(4), scope.clone(), arguments(root.path()))
                .is_err()
        );
        let mut completed = std::collections::HashSet::new();
        while let Some(reply) = tools.next_message(&host).await {
            let reply = reply?;
            let id = reply.get("id").and_then(RpcId::parse).ok_or("missing id")?;
            assert!(completed.insert(id.clone()));
            if id == RpcId::Integer(0) {
                assert_eq!(reply["error"]["data"]["status"], "cancelled");
            }
        }
        assert_eq!(completed.len(), 4);
        assert!(tools.is_empty());
        tools
            .start(RpcId::Integer(4), scope, arguments(root.path()))
            .map_err(|_| "released slot missing")?;
        tools.cancel_all();
        assert_eq!(
            tools.next_message(&host).await.ok_or("missing result")??["error"]["data"]["status"],
            "cancelled"
        );
        Ok(())
    }

    #[tokio::test]
    async fn expired_and_closed_owners_cannot_publish_success_even_after_worker_completed()
    -> TestResult {
        let root = tempfile::tempdir()?;
        for expired in [true, false] {
            let (mut host, scope) = owner()?;
            let mut tools = ReadTools::default();
            let id = RpcId::Integer(1);
            tools
                .start(id.clone(), scope.clone(), arguments(root.path()))
                .map_err(|_| "start failed")?;
            if expired {
                tools
                    .requests
                    .get_mut(&id)
                    .ok_or("missing request")?
                    .deadline = Instant::now();
            } else {
                host.dispatch(
                    "session/close",
                    json!({"application_id":scope.application_id,
                "session_id":scope.session_id}),
                    true,
                )
                .result
                .map_err(|_| "close failed")?;
            }
            tools.sweep(&host);
            let reply = tools
                .next_message(&host)
                .await
                .ok_or("missing completion")??;
            assert_eq!(
                reply["error"]["data"]["status"],
                if expired { "timeout" } else { "stale_owner" }
            );
            assert!(tools.is_empty());
        }
        Ok(())
    }

    #[tokio::test]
    async fn dropping_mailbox_revokes_workers_and_shutdown_prevents_new_admission() -> TestResult {
        let root = tempfile::tempdir()?;
        let (host, scope) = owner()?;
        let mut tools = ReadTools::default();
        let id = RpcId::Integer(1);
        tools
            .start(id.clone(), scope.clone(), arguments(root.path()))
            .map_err(|_| "start failed")?;
        let cancellation = tools
            .requests
            .get(&id)
            .ok_or("missing request")?
            .cancel
            .clone();
        drop(tools);
        assert!(cancellation.is_cancelled());
        let mut tools = ReadTools::default();
        tools.cancel_all();
        assert!(tools.start(id, scope, arguments(root.path())).is_err());
        assert!(tools.next_message(&host).await.is_none());
        Ok(())
    }
}
