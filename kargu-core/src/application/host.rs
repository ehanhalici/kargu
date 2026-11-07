//! Single-writer application/session lifecycle host for migration stage one.

use crate::application::ApplicationActor;
use crate::constants::{
    limits,
    protocol::{self, methods},
};
use crate::domain::{ApplicationId, ByteLimit, RequestScope, SessionId};
use crate::ipc::protocol::Fault;
use crate::providers::ApiProviderId;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

/// Owner of a standalone read service, not an agent run or execution grant.
#[derive(Clone, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReadScope {
    pub application_id: ApplicationId,
    pub session_id: SessionId,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadRequest<T> {
    scope: ReadScope,
    arguments: T,
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Fresh,
    Negotiated,
    Ready,
    Shutdown,
}

enum Application {
    Live(ApplicationActor),
    Draining(ApplicationActor),
}
impl Application {
    fn actor(&self) -> &ApplicationActor {
        match self {
            Self::Live(actor) | Self::Draining(actor) => actor,
        }
    }
    fn actor_mut(&mut self) -> &mut ApplicationActor {
        match self {
            Self::Live(actor) | Self::Draining(actor) => actor,
        }
    }
    fn is_live(&self) -> bool {
        matches!(self, Self::Live(_))
    }
    fn close(self) -> Self {
        let mut actor = match self {
            Self::Live(actor) | Self::Draining(actor) => actor,
        };
        actor.revoke_all();
        Self::Draining(actor)
    }
}

/// Transport-independent host. It does not admit agent runs yet.
pub struct Host {
    epoch: String,
    phase: Phase,
    frame_limit: ByteLimit,
    applications: HashMap<ApplicationId, Application>,
    providers: Result<crate::providers::ProviderCatalog, crate::error::CoreError>,
    editor_file_snapshot: bool,
}

/// Effect of dispatching one call.
pub struct Dispatch {
    /// Method result (transport adds correlation identity).
    pub result: Result<Value, Fault>,
    /// Stop reading and drain the writer.
    pub exit: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Initialize {
    protocol_major: u16,
    #[serde(rename = "protocol_minor")]
    _protocol_minor: u16,
    client_version: String,
    capabilities: Vec<String>,
    limits: Limits,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Limits {
    max_frame_bytes: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApplicationScope {
    application_id: ApplicationId,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionScope {
    application_id: ApplicationId,
    session_id: SessionId,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SelectionCommit {
    application_id: ApplicationId,
    session_id: SessionId,
    expected_revision: super::selection::SelectionRevision,
    selection: super::selection::Selection,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogPageRequest {
    offset: crate::providers::CatalogOffset,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogTargetRequest {
    connection_epoch: String,
    arguments: crate::providers::catalog_target::CatalogTargetInput,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigurationParseRequest {
    connection_epoch: String,
    arguments: crate::configuration::ParseInput,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigurationReadRequest {
    connection_epoch: String,
    arguments: crate::configuration::read::ReadInput,
}

impl Default for Host {
    fn default() -> Self {
        Self::new()
    }
}

impl Host {
    pub(crate) fn sweep_configuration(&mut self, now: std::time::Instant) {
        for application in self.applications.values_mut() {
            application.actor_mut().configuration.sweep(now);
            application.actor_mut().edits.sweep(now);
        }
    }
    /// Start a host with a fresh, non-reusable connection epoch.
    pub fn new() -> Self {
        Self {
            epoch: uuid::Uuid::new_v4().to_string(),
            phase: Phase::Fresh,
            frame_limit: ByteLimit::WIRE_MAX,
            applications: HashMap::new(),
            providers: crate::providers::ProviderCatalog::embedded(),
            editor_file_snapshot: false,
        }
    }

    /// Negotiated limit applied immediately after initialize.
    pub fn frame_limit(&self) -> ByteLimit {
        self.frame_limit
    }
    pub(crate) fn editor_file_snapshot_available(&self) -> bool {
        self.editor_file_snapshot
    }

    /// Whether this connection has finished draining its domain resources.
    pub fn is_shutdown(&self) -> bool {
        self.phase == Phase::Shutdown
    }

    pub(crate) fn owns_read_scope(&self, scope: &ReadScope) -> bool {
        self.phase == Phase::Ready
            && self
                .applications
                .get(&scope.application_id)
                .is_some_and(|entry| {
                    entry.is_live() && entry.actor().owns_session(&scope.session_id)
                })
    }

    pub(crate) fn owns_application(&self, id: &ApplicationId) -> bool {
        self.phase == Phase::Ready && self.applications.get(id).is_some_and(Application::is_live)
    }

    pub(crate) fn actor_mut(
        &mut self,
        scope: &ReadScope,
    ) -> Result<&mut ApplicationActor, crate::error::CoreError> {
        self.applications
            .get_mut(&scope.application_id)
            .map(Application::actor_mut)
            .ok_or(crate::error::CoreError::StaleOwner)
    }

    pub(crate) fn close_application(&mut self, params: Value) -> Result<ApplicationId, Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let scope: ApplicationScope =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self
            .applications
            .get(&scope.application_id)
            .ok_or_else(owner_fault)?
            .is_live()
        {
            return Err(state_fault());
        }
        let entry = self
            .applications
            .remove(&scope.application_id)
            .ok_or_else(owner_fault)?;
        self.applications
            .insert(scope.application_id.clone(), entry.close());
        Ok(scope.application_id)
    }
    pub(crate) fn release_application(
        &mut self,
        id: &ApplicationId,
    ) -> Result<bool, crate::error::CoreError> {
        match self.applications.get(id) {
            Some(Application::Draining(actor)) if actor.drained() => {}
            Some(Application::Draining(_)) => return Ok(false),
            _ => return Err(crate::error::CoreError::StaleOwner),
        }
        self.applications.remove(id);
        Ok(true)
    }

    pub(crate) fn prepare_workspace_read(
        &self,
        method: &str,
        params: Value,
    ) -> Result<(ReadScope, crate::workspace::WorkspaceRead), Fault> {
        use crate::workspace::WorkspaceRead;
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let (scope, input) = match method {
            methods::PROBE => {
                let request: ReadRequest<crate::workspace::probe::ProbeInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (request.scope, WorkspaceRead::Probe(request.arguments))
            }
            methods::WEBFETCH => {
                let request: ReadRequest<crate::workspace::webfetch::FetchInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (request.scope, WorkspaceRead::Webfetch(request.arguments))
            }
            methods::SKILLS => {
                let request: ReadRequest<crate::workspace::skills::SkillInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (request.scope, WorkspaceRead::Skills(request.arguments))
            }
            methods::READ_FILE => {
                let request: ReadRequest<crate::workspace::file::ReadFileInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (request.scope, WorkspaceRead::ReadFile(request.arguments))
            }
            methods::FIND_FILES => {
                let request: ReadRequest<crate::workspace::search::FindFilesInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (request.scope, WorkspaceRead::FindFiles(request.arguments))
            }
            _ => return Err(Fault::params()),
        };
        if !self.owns_read_scope(&scope) {
            return Err(owner_fault());
        }
        Ok((scope, input))
    }

    pub(crate) fn prepare_journal_recovery(
        &self,
        params: Value,
    ) -> Result<(ReadScope, crate::edit::journal::RecoverInput), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let request: ReadRequest<crate::edit::journal::RecoverInput> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        Ok((request.scope, request.arguments))
    }

    pub(crate) fn prepare_rollback(
        &mut self,
        params: Value,
    ) -> Result<(ReadScope, crate::edit::prepare::RollbackWork), Fault> {
        let request: ReadRequest<crate::edit::prepare::RollbackInput> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        let work = self
            .actor_mut(&request.scope)
            .map_err(|_| owner_fault())?
            .edits
            .prepare_rollback(
                &request.scope.session_id,
                request.arguments,
                std::time::Instant::now(),
            )
            .map_err(crate::edit::prepare::fault)?;
        Ok((request.scope, work))
    }

    pub(crate) fn prepare_history_import(
        &mut self,
        params: Value,
    ) -> Result<(ReadScope, crate::history::HistoryWork), Fault> {
        let request: ReadRequest<Value> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        let work = self
            .actor_mut(&request.scope)
            .map_err(crate::history::fault)?
            .prepare_history_import(&request.scope.session_id, request.arguments)
            .map_err(crate::history::fault)?;
        Ok((request.scope, work))
    }
    pub(crate) fn can_publish_history(
        &self,
        scope: &ReadScope,
        id: &crate::domain::HistoryUploadId,
    ) -> bool {
        self.owns_read_scope(scope)
            && self
                .applications
                .get(&scope.application_id)
                .is_some_and(|application| {
                    application
                        .actor()
                        .can_publish_history(&scope.session_id, id)
                })
    }
    pub(crate) fn finish_history_import(
        &mut self,
        scope: &ReadScope,
        id: &crate::domain::HistoryUploadId,
        result: Result<crate::history::History, crate::error::CoreError>,
    ) -> Result<Value, Fault> {
        let result = if self.owns_read_scope(scope) {
            result
        } else {
            Err(crate::error::CoreError::StaleOwner)
        };
        self.actor_mut(scope)
            .map_err(crate::history::fault)?
            .finish_history_import(&scope.session_id, id, result)
            .map_err(crate::history::fault)
    }
    pub(crate) fn prepare_edit(
        &mut self,
        params: Value,
        inspect: bool,
    ) -> Result<(ReadScope, crate::edit::prepare::PrepareWork), Fault> {
        let request: ReadRequest<Value> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        let work = self
            .actor_mut(&request.scope)
            .map_err(|_| owner_fault())?
            .edits
            .take(
                &request.scope.session_id,
                request.arguments,
                std::time::Instant::now(),
                inspect,
            )?;
        Ok((request.scope, work))
    }
    pub(crate) fn can_publish_edit(
        &self,
        scope: &ReadScope,
        id: &crate::edit::prepare::PreparationId,
    ) -> bool {
        self.owns_read_scope(scope)
            && self
                .applications
                .get(&scope.application_id)
                .is_some_and(|app| {
                    app.actor()
                        .edits
                        .can_publish(&scope.session_id, id, std::time::Instant::now())
                })
    }
    pub(crate) fn finish_edit(
        &mut self,
        scope: &ReadScope,
        id: &crate::edit::prepare::PreparationId,
        result: Result<crate::edit::prepare::PreparationResult, crate::error::CoreError>,
    ) -> Result<Value, Fault> {
        // Retired sessions may still own a draining worker; settlement must release it.
        let result = if self.owns_read_scope(scope) {
            result
        } else {
            Err(crate::error::CoreError::StaleOwner)
        };
        self.actor_mut(scope)
            .map_err(|_| owner_fault())?
            .edits
            .finish(&scope.session_id, id, result, std::time::Instant::now())
    }

    pub(crate) fn matches_epoch(&self, scope: &RequestScope) -> bool {
        scope.as_str() == self.epoch
    }
    pub(crate) fn owns_connection_read(&self, scope: &RequestScope) -> bool {
        self.phase == Phase::Ready && self.matches_epoch(scope)
    }
    pub(crate) fn prepare_configuration_read(
        &self,
        params: Value,
    ) -> Result<(RequestScope, crate::configuration::read::ReadInput), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let request: ConfigurationReadRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let scope =
            RequestScope::try_from(request.connection_epoch).map_err(|_| Fault::params())?;
        if !self.owns_connection_read(&scope) {
            return Err(owner_fault());
        }
        Ok((scope, request.arguments))
    }

    pub(crate) fn prepare_model_refresh(
        &self,
        params: Value,
    ) -> Result<(RequestScope, crate::ipc::ModelCatalogWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let request: ModelRefreshRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let connection =
            RequestScope::try_from(request.connection_epoch).map_err(|_| Fault::params())?;
        if !self.owns_connection_read(&connection) || !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        let provider = ApiProviderId::try_from(request.provider).map_err(|_| Fault::params())?;
        let catalog = self.providers.as_ref().map_err(|_| Fault::params())?;
        let app = self
            .applications
            .get(&request.scope.application_id)
            .ok_or_else(owner_fault)?;
        let capture = app
            .actor()
            .configuration
            .prepare_catalog(
                request.configuration_revision,
                provider.clone(),
                &request.scope.session_id,
                catalog,
            )
            .map_err(|error| match error {
                crate::error::CoreError::StaleOwner => owner_fault(),
                crate::error::CoreError::Unavailable => Fault {
                    code: protocol::error_codes::INVALID_STATE,
                    message: "Native catalog credential is unavailable",
                    status: "credential_unavailable",
                },
                _ => Fault::params(),
            })?;
        Ok((
            connection,
            crate::ipc::ModelCatalogWork {
                owner: request.scope,
                configuration_revision: request.configuration_revision,
                provider: provider.clone(),
                request: capture,
                specs: catalog.effort_specs(&provider),
            },
        ))
    }

    pub(crate) fn owns_model_refresh(
        &self,
        scope: &ReadScope,
        revision: crate::domain::ConfigRevision,
    ) -> bool {
        self.owns_read_scope(scope)
            && self
                .applications
                .get(&scope.application_id)
                .is_some_and(|app| app.actor().configuration.is_revision(revision))
    }

    pub(crate) fn update_provider_models(
        &mut self,
        connection: &RequestScope,
        owner: &ReadScope,
        revision: crate::domain::ConfigRevision,
        provider: ApiProviderId,
        catalog: crate::models::catalog::ModelCatalog,
        specs: crate::models::metadata::EffortSpecs,
    ) -> Result<(), crate::error::CoreError> {
        if !self.owns_connection_read(connection) || !self.owns_model_refresh(owner, revision) {
            return Err(crate::error::CoreError::StaleOwner);
        }
        self.actor_mut(owner)?
            .models
            .store_mut()
            .update_catalog(provider, catalog, specs)
            .map(|_| ())
            .map_err(|_| crate::error::CoreError::Unavailable)
    }
    pub(crate) fn request_scope(&self) -> Result<RequestScope, crate::error::CoreError> {
        RequestScope::try_from(self.epoch.clone())
    }

    /// Dispatch a request or notification; state-changing methods require ids.
    pub fn dispatch(&mut self, method: &str, params: Value, request: bool) -> Dispatch {
        self.dispatch_budgeted(method, params, request, self.frame_limit)
    }
    pub(crate) fn dispatch_rpc(
        &mut self,
        method: &str,
        params: Value,
        id: Option<&crate::ipc::protocol::RpcId>,
    ) -> Dispatch {
        let response_limit = match id.map(|id| id.result_budget(self.frame_limit)).transpose() {
            Ok(limit) => limit.unwrap_or(self.frame_limit),
            Err(_) => {
                return Dispatch {
                    result: Err(Fault {
                        code: protocol::error_codes::RESOURCE_LIMIT,
                        status: "resource_limit",
                        message: "Response envelope exceeds negotiated frame limit",
                    }),
                    exit: false,
                };
            }
        };
        self.dispatch_budgeted(method, params, id.is_some(), response_limit)
    }
    fn dispatch_budgeted(
        &mut self,
        method: &str,
        params: Value,
        request: bool,
        response_limit: ByteLimit,
    ) -> Dispatch {
        if method == methods::EXIT && !request {
            return Dispatch {
                result: Ok(Value::Null),
                exit: true,
            };
        }
        if method == methods::INITIALIZED && !request {
            let result = if self.phase == Phase::Negotiated && empty_params(&params) {
                self.phase = Phase::Ready;
                Ok(Value::Null)
            } else {
                Err(state_fault())
            };
            return Dispatch {
                result,
                exit: false,
            };
        }
        let result = if !request {
            Err(Fault::invalid())
        } else if method == methods::INITIALIZE {
            self.initialize(params)
        } else if method == methods::SHUTDOWN
            && self.phase != Phase::Fresh
            && self.phase != Phase::Shutdown
        {
            if empty_params(&params) {
                self.phase = Phase::Shutdown;
                Ok(Value::Null)
            } else {
                Err(Fault::params())
            }
        } else if self.phase != Phase::Ready {
            Err(state_fault())
        } else {
            self.ready_call(method, params, response_limit)
        };
        Dispatch {
            result,
            exit: false,
        }
    }

    fn initialize(&mut self, params: Value) -> Result<Value, Fault> {
        if self.phase != Phase::Fresh {
            return Err(state_fault());
        }
        let init: Initialize = serde_json::from_value(params).map_err(|_| Fault::params())?;
        if init.client_version.is_empty()
            || init.client_version.len() > limits::CLIENT_VERSION_BYTES
            || init.capabilities.len() > limits::CLIENT_CAPABILITIES
            || init.limits.max_frame_bytes < limits::MIN_FRAME_BYTES
        {
            return Err(Fault::params());
        }
        if init.protocol_major != protocol::MAJOR {
            return Err(Fault {
                code: protocol::error_codes::INCOMPATIBLE_VERSION,
                message: "Incompatible protocol version",
                status: "incompatible_version",
            });
        }
        self.frame_limit =
            ByteLimit::try_from(init.limits.max_frame_bytes.min(limits::MAX_FRAME_BYTES))
                .map_err(|_| Fault::params())?;
        self.editor_file_snapshot = init
            .capabilities
            .iter()
            .any(|capability| capability == "editor_file_snapshot");
        self.phase = Phase::Negotiated;
        Ok(
            json!({"core_version":crate::VERSION, "protocol_major":protocol::MAJOR,
            "protocol_minor":protocol::MINOR, "connection_epoch":self.epoch,
            "capabilities":protocol::LIFECYCLE_CAPABILITIES,
            "limits":{"max_frame_bytes":self.frame_limit,"max_pending_requests":limits::MAX_PENDING}}),
        )
    }

    fn ready_call(
        &mut self,
        method: &str,
        params: Value,
        response_limit: ByteLimit,
    ) -> Result<Value, Fault> {
        match method {
            methods::HISTORY_BEGIN | methods::HISTORY_APPEND | methods::HISTORY_ABORT => {
                let request: ReadRequest<Value> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self.owns_read_scope(&request.scope) {
                    return Err(owner_fault());
                }
                self.actor_mut(&request.scope)
                    .map_err(crate::history::fault)?
                    .history_rpc(
                        &request.scope.session_id,
                        method,
                        request.arguments,
                        response_limit,
                    )
            }
            methods::HISTORY_MESSAGES | methods::HISTORY_READ => {
                let request: ReadRequest<Value> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self.owns_read_scope(&request.scope) {
                    return Err(owner_fault());
                }
                self.actor_mut(&request.scope)
                    .map_err(crate::history::fault)?
                    .session_history(&request.scope.session_id)
                    .map_err(crate::history::fault)?
                    .read_rpc(method, request.arguments, response_limit)
            }
            methods::EDIT_BEGIN
            | methods::EDIT_TARGETS
            | methods::EDIT_DOCUMENT
            | methods::EDIT_FILES
            | methods::EDIT_APPEND
            | methods::EDIT_READ
            | methods::EDIT_HISTORY
            | methods::EDIT_ABORT
            | methods::EDIT_CLOSE => {
                let request: ReadRequest<Value> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self.owns_read_scope(&request.scope) {
                    return Err(owner_fault());
                }
                let frame = response_limit;
                self.actor_mut(&request.scope)
                    .map_err(|_| owner_fault())?
                    .edits
                    .rpc(
                        &request.scope.session_id,
                        method,
                        request.arguments,
                        frame,
                        std::time::Instant::now(),
                    )
            }
            "configuration/prepare"
            | "configuration/commit"
            | "configuration/abort"
            | "configuration/snapshot"
            | "configuration/resolve"
            | "configuration/select" => {
                let request: ReadRequest<Value> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self.owns_read_scope(&request.scope) {
                    return Err(owner_fault());
                }
                let catalog = self.providers.as_ref().map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&request.scope.application_id)
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                actor.configuration.rpc(
                    &request.scope.session_id,
                    method,
                    request.arguments,
                    catalog,
                    response_limit,
                    std::time::Instant::now(),
                )
            }
            methods::MODEL_BEGIN
            | methods::MODEL_APPEND
            | methods::MODEL_COMMIT
            | methods::MODEL_ABORT
            | methods::MODEL_SNAPSHOT
            | methods::MODEL_READ => {
                let request: ReadRequest<Value> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self.owns_read_scope(&request.scope) {
                    return Err(owner_fault());
                }
                let frame = response_limit;
                self.actor_mut(&request.scope)
                    .map_err(|_| owner_fault())?
                    .models
                    .rpc(
                        &request.scope.session_id,
                        method,
                        request.arguments,
                        frame,
                        std::time::Instant::now(),
                    )
            }
            methods::PING if empty_params(&params) => Ok(json!({"status":"ok"})),
            methods::PING => Err(Fault::params()),
            methods::PROVIDER_CATALOG if empty_params(&params) => self
                .providers
                .as_ref()
                .map(crate::providers::ProviderCatalog::snapshot)
                .map_err(|_| Fault {
                    code: protocol::error_codes::INVALID_STATE,
                    message: "Provider manifest is invalid",
                    status: "invalid_catalog",
                }),
            methods::PROVIDER_CATALOG => {
                let request: CatalogPageRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let catalog = self.providers.as_ref().map_err(|_| Fault {
                    code: protocol::error_codes::INVALID_STATE,
                    message: "Provider manifest is invalid",
                    status: "invalid_catalog",
                })?;
                catalog
                    .page(request.offset, response_limit)
                    .map_err(|_| Fault::params())
            }
            methods::PROVIDER_CATALOG_TARGET => self.catalog_target(params),
            methods::PROVIDER_LIST => self.provider_list(params),
            methods::MODEL_LIST => self.model_list(params),
            methods::CONFIGURATION_PARSE => self.configuration_parse(params),
            methods::APPLICATION_CREATE => {
                if !empty_params(&params) {
                    return Err(Fault::params());
                }
                if self.applications.len() >= limits::MAX_APPLICATIONS {
                    return Err(capacity_fault());
                }
                let id = ApplicationId::new();
                let registry = crate::security::ToolRegistry::standard().map_err(|_| Fault {
                    code: protocol::error_codes::INVALID_STATE,
                    message: "Tool manifest is invalid",
                    status: "invalid_catalog",
                })?;
                self.applications.insert(
                    id.clone(),
                    Application::Live(ApplicationActor::with_registry(id.clone(), registry)),
                );
                Ok(json!({"application_id":id}))
            }
            methods::SESSION_CREATE => {
                let scope: ApplicationScope =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                if !self
                    .applications
                    .get(&scope.application_id)
                    .is_some_and(Application::is_live)
                {
                    return Err(owner_fault());
                }
                if self
                    .applications
                    .values()
                    .map(|entry| entry.actor().session_count())
                    .sum::<usize>()
                    >= limits::MAX_SESSIONS
                {
                    return Err(capacity_fault());
                }
                let actor = self
                    .applications
                    .get_mut(&scope.application_id)
                    .ok_or_else(owner_fault)?;
                let id = actor.actor_mut().create_session();
                Ok(json!({"application_id":scope.application_id,"session_id":id}))
            }
            methods::SESSION_SNAPSHOT | methods::SESSION_CLOSE => {
                let scope: SessionScope =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&scope.application_id)
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                if !actor.owns_session(&scope.session_id) {
                    return Err(owner_fault());
                }
                if method == methods::SESSION_CLOSE {
                    actor
                        .revoke_session(&scope.session_id)
                        .map_err(|_| owner_fault())?;
                    Ok(json!({"status":"closed"}))
                } else {
                    let mut snapshot = actor
                        .session_projection(&scope.session_id)
                        .map_err(|_| owner_fault())?;
                    let fields = snapshot.as_object_mut().ok_or_else(owner_fault)?;
                    fields.insert("connection_epoch".to_owned(), json!(self.epoch));
                    fields.insert("application_id".to_owned(), json!(scope.application_id));
                    fields.insert("session_id".to_owned(), json!(scope.session_id));
                    Ok(snapshot)
                }
            }
            methods::SESSION_SELECTION => {
                let scope: SessionScope =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get(&scope.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor();
                let store = actor
                    .session_selection(&scope.session_id)
                    .map_err(|_| owner_fault())?;
                Ok(json!({"revision":store.revision(),"selection":store.selection()}))
            }
            methods::SESSION_SELECTION_COMMIT => {
                let request: SelectionCommit =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                if !actor.owns_session(&request.session_id) {
                    return Err(owner_fault());
                }
                let store = actor
                    .commit_session_selection(
                        &request.session_id,
                        request.expected_revision,
                        request.selection,
                    )
                    .map_err(selection_fault)?;
                Ok(json!({"revision":store.revision(),"selection":store.selection()}))
            }
            _ => Err(Fault {
                code: protocol::error_codes::METHOD_NOT_FOUND,
                message: "Method not found",
                status: "unavailable",
            }),
        }
    }

    fn catalog_target(&self, params: Value) -> Result<Value, Fault> {
        let request: CatalogTargetRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let epoch =
            RequestScope::try_from(request.connection_epoch).map_err(|_| Fault::params())?;
        if !self.matches_epoch(&epoch) {
            return Err(owner_fault());
        }
        let target = request.arguments.resolve().map_err(|_| Fault::params())?;
        serde_json::to_value(target).map_err(|_| Fault::params())
    }

    fn configuration_parse(&self, params: Value) -> Result<Value, Fault> {
        let request: ConfigurationParseRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let epoch =
            RequestScope::try_from(request.connection_epoch).map_err(|_| Fault::params())?;
        if !self.matches_epoch(&epoch) {
            return Err(owner_fault());
        }
        Ok(request.arguments.resolve())
    }

    fn provider_list(&self, params: Value) -> Result<Value, Fault> {
        let req: ProviderListRequest =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if let Some(ref epoch_str) = req.connection_epoch {
            let epoch = RequestScope::try_from(epoch_str.clone()).map_err(|_| Fault::params())?;
            if !self.matches_epoch(&epoch) {
                return Err(owner_fault());
            }
        }
        let catalog = self.providers.as_ref().map_err(|_| Fault {
            code: protocol::error_codes::INVALID_STATE,
            message: "Provider manifest is invalid",
            status: "invalid_catalog",
        })?;

        let app = match req.application_id.as_ref() {
            Some(id) => Some(
                self.applications
                    .get(id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?,
            ),
            None => None,
        };
        let configured_profiles = app
            .and_then(|app| app.actor().configuration.published_view())
            .and_then(|view| view.get("profiles").and_then(Value::as_array).cloned())
            .unwrap_or_default();

        let mut seen = std::collections::BTreeSet::new();
        let mut items = Vec::new();

        // 1. Process configured profiles first
        for profile in configured_profiles {
            let Some(p_id) = profile.get("provider").and_then(|v| v.as_str()) else {
                continue;
            };
            if !seen.insert(p_id.to_string()) {
                continue;
            }
            let api_p_id = match ApiProviderId::try_from(p_id.to_string()) {
                Ok(id) => id,
                Err(_) => continue,
            };
            let embedded_def = catalog.get(&api_p_id);
            let name = embedded_def
                .map(|d| d.name().as_str().to_string())
                .unwrap_or_else(|| capitalize_provider(p_id));
            let is_local = profile
                .get("local")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                || embedded_def.is_some_and(|d| d.local());
            let cred_source = profile
                .get("credential_source")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let authenticated = profile
                .get("authenticated")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                || is_local;
            let status = if is_local {
                "local"
            } else if cred_source == "environment" {
                "env_key"
            } else if authenticated {
                "configured"
            } else {
                "available"
            };
            let default_model = profile
                .get("configured_model")
                .and_then(|v| v.as_str())
                .or_else(|| profile.get("model").and_then(|v| v.as_str()))
                .map(String::from);
            let models: Vec<String> = profile
                .get("models")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();

            items.push(json!({
                "id": p_id,
                "name": name,
                "status": status,
                "authenticated": authenticated,
                "default_model": default_model,
                "models": models,
                "local": is_local,
            }));
        }

        let auth_only = req.authenticated_only.unwrap_or(false);

        // 2. Add embedded definitions not yet seen if authenticated_only is false
        if !auth_only {
            for def in catalog.definitions() {
                let p_id = def.id().as_str();
                if !seen.insert(p_id.to_string()) {
                    continue;
                }
                let is_local = def.local();
                let authenticated = is_local || def.keyless();
                let status = if is_local {
                    "local"
                } else if authenticated {
                    "configured"
                } else {
                    "available"
                };
                items.push(json!({
                    "id": p_id,
                    "name": def.name().as_str(),
                    "status": status,
                    "authenticated": authenticated,
                    "default_model": null,
                    "models": Vec::<String>::new(),
                    "local": is_local,
                }));
            }
        }

        let connected: Vec<String> = items
            .iter()
            .filter(|it| {
                it.get("authenticated")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
            })
            .filter_map(|it| it.get("id").and_then(|v| v.as_str()).map(String::from))
            .collect();

        if auth_only {
            items.retain(|it| {
                it.get("authenticated")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
            });
        }

        Ok(json!({
            "status": "ok",
            "providers": items,
            "connected": connected
        }))
    }

    fn model_list(&self, params: Value) -> Result<Value, Fault> {
        let req: ModelListRequest = serde_json::from_value(params).map_err(|_| Fault::params())?;
        if let Some(ref epoch_str) = req.connection_epoch {
            let epoch = RequestScope::try_from(epoch_str.clone()).map_err(|_| Fault::params())?;
            if !self.matches_epoch(&epoch) {
                return Err(owner_fault());
            }
        }
        let provider_id =
            ApiProviderId::try_from(req.provider.clone()).map_err(|_| Fault::params())?;
        let app = match req.application_id.as_ref() {
            Some(id) => Some(
                self.applications
                    .get(id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?,
            ),
            None => None,
        };

        let mut models = if let Some(app) = app {
            app.actor().models.provider_models(&provider_id)
        } else {
            Vec::new()
        };

        // If models are not in ModelStore yet, check published config profile
        if models.is_empty()
            && let Some(app) = app
            && let Some(view) = app.actor().configuration.published_view()
            && let Some(profiles) = view.get("profiles").and_then(|p| p.as_array())
        {
            for prof in profiles {
                if prof.get("provider").and_then(|v| v.as_str()) == Some(req.provider.as_str()) {
                    let mut seen_ids = std::collections::BTreeSet::new();
                    if let Some(cfg_m) = prof.get("configured_model").and_then(|v| v.as_str())
                        && !cfg_m.is_empty()
                        && seen_ids.insert(cfg_m.to_string())
                    {
                        models.push(create_fallback_model_dto(cfg_m));
                    }
                    if let Some(m) = prof.get("model").and_then(|v| v.as_str())
                        && !m.is_empty()
                        && seen_ids.insert(m.to_string())
                    {
                        models.push(create_fallback_model_dto(m));
                    }
                    if let Some(arr) = prof.get("models").and_then(|v| v.as_array()) {
                        for item in arr {
                            if let Some(m_str) = item.as_str()
                                && !m_str.is_empty()
                                && seen_ids.insert(m_str.to_string())
                            {
                                models.push(create_fallback_model_dto(m_str));
                            }
                        }
                    }
                }
            }
        }

        let mut is_fallback = false;
        // Default fallbacks if completely empty based on provider name
        if models.is_empty() {
            is_fallback = true;
            match req.provider.as_str() {
                "openrouter" => {
                    models.push(create_fallback_model_dto("anthropic/claude-3.5-sonnet"));
                    models.push(create_fallback_model_dto("openai/gpt-4o"));
                }
                "opencode" => {
                    models.push(create_fallback_model_dto("nemotron-3-ultra-free"));
                }
                "nvidia" => {
                    models.push(create_fallback_model_dto("meta/llama-3.1-70b-instruct"));
                }
                _ => {}
            }
        }

        Ok(json!({
            "status": "ok",
            "provider": req.provider,
            "models": models,
            "cached": !is_fallback,
            "fallback": is_fallback
        }))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelRefreshRequest {
    connection_epoch: String,
    scope: ReadScope,
    configuration_revision: crate::domain::ConfigRevision,
    provider: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderListRequest {
    #[serde(default)]
    connection_epoch: Option<String>,
    #[serde(default)]
    application_id: Option<ApplicationId>,
    #[serde(default)]
    authenticated_only: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelListRequest {
    #[serde(default)]
    connection_epoch: Option<String>,
    #[serde(default)]
    application_id: Option<ApplicationId>,
    provider: String,
    #[serde(default, rename = "refresh")]
    _refresh: bool,
}

fn capitalize_provider(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
    }
}

fn create_fallback_model_dto(id: &str) -> crate::models::store::ModelSummaryDto {
    let lower = id.to_lowercase();
    let has_reasoning = lower.contains("r1")
        || lower.contains("o1")
        || lower.contains("o3")
        || lower.contains("reason")
        || lower.contains("thinking");
    let efforts = if has_reasoning {
        vec!["low".to_string(), "medium".to_string(), "high".to_string()]
    } else {
        Vec::new()
    };
    let is_free = lower.contains("free");
    crate::models::store::ModelSummaryDto {
        id: id.to_string(),
        context_window: Some(128_000),
        max_output: Some(4096),
        reasoning_efforts: efforts,
        price_label: if is_free {
            Some("free".to_string())
        } else {
            None
        },
        free: is_free,
        vision: lower.contains("vision") || lower.contains("vl"),
        supports_tools: true,
        supports_reasoning: has_reasoning,
    }
}

fn empty_params(value: &Value) -> bool {
    value.as_object().is_some_and(|v| v.is_empty())
}
fn state_fault() -> Fault {
    Fault {
        code: protocol::error_codes::INVALID_STATE,
        message: "Invalid connection state",
        status: "invalid_state",
    }
}
fn owner_fault() -> Fault {
    Fault {
        code: protocol::error_codes::STALE_OWNER,
        message: "Unknown or foreign owner",
        status: "stale_owner",
    }
}
fn selection_fault(error: crate::error::CoreError) -> Fault {
    match error {
        crate::error::CoreError::Busy => Fault {
            code: protocol::error_codes::INVALID_STATE,
            message: "Active work owns the selection",
            status: "busy",
        },
        crate::error::CoreError::StaleOwner => Fault {
            code: protocol::error_codes::STALE_OWNER,
            message: "Selection revision or owner is stale",
            status: "stale_revision",
        },
        _ => owner_fault(),
    }
}
fn capacity_fault() -> Fault {
    Fault {
        code: protocol::error_codes::RESOURCE_LIMIT,
        message: "Resource limit reached",
        status: "resource_limit",
    }
}
