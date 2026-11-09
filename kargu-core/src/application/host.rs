//! Single-writer application/session lifecycle host for migration stage one.

use crate::application::ApplicationActor;
use crate::constants::{
    limits,
    protocol::{self, methods},
};
use crate::domain::rpc::Fault;
use crate::domain::{ApplicationId, ByteLimit, PlanId, PlanRevision, RequestScope, SessionId};
use crate::persistence::{
    CollisionPolicy, DeleteTask, ImportTask, ListTask, LoadTask, MaxSessionAge, MaxSessionBytes,
    MaxSessionCount, PersistenceTarget, PersistenceWork, PruneTask, RawSessionPayload, SaveTask,
    SessionRecord, SessionRetentionPolicy, StorageRevision, StorageSessionId, migrate_candidate,
};
use crate::providers::{ApiProviderId, ProviderCatalog};
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistenceSaveParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
    expected_revision: u64,
    #[serde(default)]
    session_id: Option<String>,
    record: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistenceLoadParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    expected_revision: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistenceListParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistenceDeleteParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    expected_revision: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistenceImportParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
    /// A caller-supplied payload; exclusive with `source`.
    #[serde(default)]
    source_payload: Option<Value>,
    /// Another storage location the worker reads the session from.
    #[serde(default)]
    source: Option<crate::persistence::StorageLocation>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    collision: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistencePruneParams {
    scope: ReadScope,
    storage: crate::persistence::StorageLocation,
    #[serde(default)]
    max_count: Option<usize>,
    #[serde(default)]
    max_bytes: Option<u64>,
    #[serde(default)]
    max_age_secs: Option<u64>,
    #[serde(default)]
    active_sessions: Option<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionRestoreParams {
    application_id: ApplicationId,
    #[serde(default)]
    session_id: Option<SessionId>,
    #[serde(alias = "record")]
    candidate: Value,
    #[serde(default)]
    expected_root: Option<std::path::PathBuf>,
}

fn parse_collision_policy(
    collision: Option<&str>,
    session_id: &StorageSessionId,
) -> Result<CollisionPolicy, Fault> {
    match collision {
        None | Some("reject") => Ok(CollisionPolicy::Reject),
        Some("override") => Ok(CollisionPolicy::Override(session_id.clone())),
        Some("derive_with_prefix") => Ok(CollisionPolicy::DeriveWithPrefix(session_id.clone())),
        _ => Err(Fault::params()),
    }
}

fn parse_active_sessions(
    scope: &ReadScope,
    extra: Option<Vec<String>>,
) -> Result<std::collections::BTreeSet<StorageSessionId>, Fault> {
    let mut active = std::collections::BTreeSet::new();
    let scope_sid =
        StorageSessionId::try_from(scope.session_id.as_str()).map_err(|_| Fault::params())?;
    active.insert(scope_sid);
    if let Some(extra_ids) = extra {
        for id_str in extra_ids {
            let sid = StorageSessionId::try_from(id_str.as_str()).map_err(|_| Fault::params())?;
            active.insert(sid);
        }
    }
    Ok(active)
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

/// Transport-independent application/session host and negotiated editor capabilities.
pub struct Host {
    epoch: String,
    phase: Phase,
    frame_limit: ByteLimit,
    applications: HashMap<ApplicationId, Application>,
    providers: Result<crate::providers::ProviderCatalog, crate::error::CoreError>,
    editor_file_snapshot: bool,
    editor_credential_capture: bool,
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
struct ModeCommit {
    application_id: ApplicationId,
    session_id: SessionId,
    expected_revision: super::mode::ModeRevision,
    mode: super::Mode,
    #[serde(default)]
    debug_ready: super::mode::DebugReady,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanQuery {
    application_id: ApplicationId,
    session_id: SessionId,
    #[serde(default)]
    plan_id: Option<PlanId>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanCreateRequest {
    application_id: ApplicationId,
    session_id: SessionId,
    text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanReviseRequest {
    application_id: ApplicationId,
    session_id: SessionId,
    plan_id: PlanId,
    expected_revision: PlanRevision,
    text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanClaimRequest {
    application_id: ApplicationId,
    session_id: SessionId,
    plan_id: PlanId,
    expected_revision: PlanRevision,
    expected_hash: super::plan::PlanHash,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanCompleteRequest {
    application_id: ApplicationId,
    session_id: SessionId,
    plan_id: PlanId,
    success: super::plan::PlanDispatchSuccess,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanRejectRequest {
    application_id: ApplicationId,
    session_id: SessionId,
    plan_id: PlanId,
    expected_revision: PlanRevision,
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigurationLocations {
    home: Option<String>,
    xdg_config_home: Option<String>,
    user_emacs_directory: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigurationRefreshArguments {
    #[serde(default)]
    paths: Option<Vec<crate::configuration::read::ConfigurationPath>>,
    #[serde(default)]
    locations: Option<ConfigurationLocations>,
    registry: crate::configuration::policy::RegistrySnapshot,
    #[serde(default)]
    defaults_only: bool,
    #[serde(default)]
    timeout_ms: crate::configuration::read::ConfigurationTimeout,
}

/// Captured staging inputs for one natively ordered refresh.
pub(crate) struct ConfigurationRefreshMeta {
    generation: crate::configuration::RefreshGeneration,
    registry: crate::configuration::policy::RegistrySnapshot,
    timeout: crate::configuration::read::ConfigurationTimeout,
}

/// Admission result: an immediate reply or a worker read.
pub(crate) enum ConfigurationRefreshStart {
    Reply(Value),
    Read(
        ReadScope,
        crate::configuration::read::ReadInput,
        ConfigurationRefreshMeta,
    ),
}

/// A prepared model-catalog fetch the transport executes off the actor.
pub(crate) struct ModelCatalogWork {
    pub owner: ReadScope,
    pub configuration_revision: crate::domain::ConfigRevision,
    pub provider: crate::providers::ApiProviderId,
    pub request: crate::api::HttpRequest,
    pub specs: crate::models::metadata::EffortSpecs,
}

/// Native precedence: explicit grants, else XDG config, then the Emacs directory.
fn configuration_candidates(
    paths: Option<Vec<crate::configuration::read::ConfigurationPath>>,
    locations: Option<ConfigurationLocations>,
) -> Result<Vec<crate::configuration::read::ConfigurationPath>, crate::error::CoreError> {
    use crate::configuration::read::ConfigurationPath;
    use std::path::PathBuf;
    let invalid = || crate::error::CoreError::InvalidValue {
        field: "configuration_locations",
    };
    match (paths, locations) {
        (Some(paths), None) => Ok(paths),
        (None, Some(locations)) => {
            let absolute =
                |value: Option<String>| value.map(PathBuf::from).filter(|path| path.is_absolute());
            let base = absolute(locations.xdg_config_home)
                .or_else(|| absolute(locations.home).map(|home| home.join(".config")))
                .ok_or_else(invalid)?;
            [
                base.join("kargu").join("config.toml"),
                PathBuf::from(locations.user_emacs_directory).join("kargu.toml"),
            ]
            .into_iter()
            .map(|path| {
                path.to_str()
                    .ok_or_else(invalid)
                    .and_then(|text| ConfigurationPath::try_from(text.to_owned()))
            })
            .collect()
        }
        _ => Err(invalid()),
    }
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
            editor_credential_capture: false,
        }
    }

    /// Negotiated limit applied immediately after initialize.
    pub fn frame_limit(&self) -> ByteLimit {
        self.frame_limit
    }
    pub(crate) fn editor_credential_available(&self) -> bool {
        self.editor_credential_capture
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
            methods::MENTION_CANDIDATES => {
                let request: ReadRequest<crate::workspace::completion::MentionCandidatesInput> =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                (
                    request.scope,
                    WorkspaceRead::MentionCandidates(request.arguments),
                )
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

    pub(crate) fn prepare_configuration_refresh(
        &mut self,
        params: Value,
        response_limit: ByteLimit,
    ) -> Result<ConfigurationRefreshStart, Fault> {
        use crate::configuration::policy::{RefreshStart, configuration_fault};
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let request: ReadRequest<ConfigurationRefreshArguments> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&request.scope) {
            return Err(owner_fault());
        }
        let arguments = request.arguments;
        let candidates = configuration_candidates(arguments.paths, arguments.locations)
            .map_err(configuration_fault)?;
        let first = candidates
            .first()
            .ok_or_else(Fault::params)?
            .as_path()
            .to_owned();
        let catalog = self.providers.as_ref().map_err(|_| Fault::params())?;
        let actor = self
            .applications
            .get_mut(&request.scope.application_id)
            .ok_or_else(owner_fault)?
            .actor_mut();
        let start = actor
            .configuration
            .begin_refresh(arguments.defaults_only)
            .map_err(configuration_fault)?;
        match start {
            RefreshStart::Observed => Ok(ConfigurationRefreshStart::Reply(
                json!({"status":"observed","revision":actor.configuration.revision()}),
            )),
            RefreshStart::Defaults(generation) => actor
                .configuration
                .stage_refresh(
                    &request.scope.session_id,
                    generation,
                    json!({"status":"absent","path":first}),
                    arguments.registry,
                    arguments.timeout_ms,
                    catalog,
                    response_limit,
                    std::time::Instant::now(),
                )
                .map(ConfigurationRefreshStart::Reply)
                .map_err(configuration_fault),
            RefreshStart::Read(generation) => {
                let input = crate::configuration::read::ReadInput::native(
                    candidates,
                    generation,
                    arguments.timeout_ms,
                )
                .map_err(configuration_fault)?;
                Ok(ConfigurationRefreshStart::Read(
                    request.scope,
                    input,
                    ConfigurationRefreshMeta {
                        generation,
                        registry: arguments.registry,
                        timeout: arguments.timeout_ms,
                    },
                ))
            }
        }
    }

    /// Natively resolve the prompt target for a conversation at `revision`.
    pub(crate) fn prompt_target(
        &self,
        scope: &ReadScope,
        revision: crate::domain::ConfigRevision,
    ) -> Result<crate::configuration::policy::RunTarget, crate::error::CoreError> {
        let catalog = self
            .providers
            .as_ref()
            .map_err(|_| crate::error::CoreError::Unavailable)?;
        let actor = self
            .applications
            .get(&scope.application_id)
            .filter(|app| app.is_live())
            .ok_or(crate::error::CoreError::StaleOwner)?
            .actor();
        let selection = actor.session_selection(&scope.session_id)?.selection();
        actor.configuration.run_target(
            revision,
            selection.provider().as_ref(),
            selection
                .model
                .as_ref()
                .map(super::selection::ModelChoice::as_str),
            catalog,
        )
    }

    /// Read model policy from this application's actual store, never the request DTO.
    pub(crate) fn run_model_policy(
        &self,
        scope: &ReadScope,
        target: &crate::configuration::policy::RunTarget,
    ) -> Result<crate::models::store::RunModelPolicy, crate::error::CoreError> {
        let actor = self
            .applications
            .get(&scope.application_id)
            .filter(|app| app.is_live())
            .ok_or(crate::error::CoreError::StaleOwner)?
            .actor();
        let provider = crate::providers::ApiProviderId::try_from(target.provider.clone())?;
        let model = crate::api::ModelId::try_from(
            target
                .model
                .clone()
                .ok_or(crate::error::CoreError::Unavailable)?,
        )
        .map_err(|_| crate::error::CoreError::Unavailable)?;
        actor
            .models
            .store()
            .run_policy(&provider, &model)
            .map_err(|_| crate::error::CoreError::Unavailable)
    }

    /// Capture the application's native metadata publication before preparation IO.
    pub(crate) fn model_revision(
        &self,
        scope: &ReadScope,
    ) -> Result<crate::models::store::MetadataRevision, crate::error::CoreError> {
        let actor = self
            .applications
            .get(&scope.application_id)
            .filter(|app| app.is_live())
            .ok_or(crate::error::CoreError::StaleOwner)?
            .actor();
        actor.session_selection(&scope.session_id)?;
        Ok(actor.models.store().revision())
    }

    pub(crate) fn prepare_persistence_save(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistenceSaveParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let session_id = match args.session_id.as_deref() {
            Some(sid) => StorageSessionId::try_from(sid).map_err(|_| Fault::params())?,
            None => StorageSessionId::try_from(args.scope.session_id.as_str())
                .map_err(|_| Fault::params())?,
        };
        // A save always carries the caller's record; never overwrite a session with a
        // blank one. The record passes the bounded, schema-checked constructor.
        let record =
            SessionRecord::try_from(args.record.to_string()).map_err(|_| Fault::params())?;
        if record.id() != &session_id {
            return Err(Fault::params());
        }
        let target = PersistenceTarget::new(storage_root, session_id);
        let work = PersistenceWork::Save(SaveTask::new(
            target,
            StorageRevision::from_u64(args.expected_revision),
            Box::new(record),
        ));
        Ok((args.scope, work))
    }

    pub(crate) fn prepare_persistence_load(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistenceLoadParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let session_id = match args.session_id.as_deref() {
            Some(sid) => StorageSessionId::try_from(sid).map_err(|_| Fault::params())?,
            None => StorageSessionId::try_from(args.scope.session_id.as_str())
                .map_err(|_| Fault::params())?,
        };
        let target = PersistenceTarget::new(storage_root, session_id);
        let work = PersistenceWork::Load(LoadTask::new(
            target,
            args.expected_revision.map(StorageRevision::from_u64),
        ));
        Ok((args.scope, work))
    }

    pub(crate) fn prepare_persistence_list(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistenceListParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let work = PersistenceWork::List(ListTask::new(storage_root));
        Ok((args.scope, work))
    }

    pub(crate) fn prepare_persistence_delete(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistenceDeleteParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let session_id = match args.session_id.as_deref() {
            Some(sid) => StorageSessionId::try_from(sid).map_err(|_| Fault::params())?,
            None => StorageSessionId::try_from(args.scope.session_id.as_str())
                .map_err(|_| Fault::params())?,
        };
        let target = PersistenceTarget::new(storage_root, session_id);
        let work = PersistenceWork::Delete(DeleteTask::new(
            target,
            args.expected_revision.map(StorageRevision::from_u64),
        ));
        Ok((args.scope, work))
    }

    pub(crate) fn prepare_persistence_import(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistenceImportParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let session_id = match args.session_id.as_deref() {
            Some(sid) => StorageSessionId::try_from(sid).map_err(|_| Fault::params())?,
            None => StorageSessionId::try_from(args.scope.session_id.as_str())
                .map_err(|_| Fault::params())?,
        };
        let collision = parse_collision_policy(args.collision.as_deref(), &session_id)?;
        let task = match (args.source_payload, args.source) {
            (Some(payload), None) => {
                let raw_payload = RawSessionPayload::try_from(match payload {
                    Value::String(s) => s,
                    other => other.to_string(),
                })
                .map_err(|_| Fault::params())?;
                let candidate =
                    migrate_candidate(&raw_payload, &collision).map_err(|_| Fault::params())?;
                ImportTask::new(storage_root, Box::new(candidate))
            }
            (None, Some(source)) => {
                ImportTask::from_location(storage_root, source, (session_id, collision))
            }
            _ => return Err(Fault::params()),
        };
        let work = PersistenceWork::Import(task);
        Ok((args.scope, work))
    }

    pub(crate) fn prepare_persistence_prune(
        &self,
        params: Value,
    ) -> Result<(ReadScope, PersistenceWork), Fault> {
        if self.phase != Phase::Ready {
            return Err(state_fault());
        }
        let args: PersistencePruneParams =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !self.owns_read_scope(&args.scope) {
            return Err(owner_fault());
        }
        let storage_root = args.storage;
        let policy = SessionRetentionPolicy::new(
            args.max_count.map(MaxSessionCount::from_usize),
            args.max_bytes.map(MaxSessionBytes::from_u64),
            args.max_age_secs.map(MaxSessionAge::from_secs),
        );
        let active = parse_active_sessions(&args.scope, args.active_sessions)?;
        let work = PersistenceWork::Prune(PruneTask::new(storage_root, policy, active));
        Ok((args.scope, work))
    }

    /// Whether `revision` is still the application's published configuration.
    pub(crate) fn configuration_current(
        &self,
        scope: &ReadScope,
        revision: crate::domain::ConfigRevision,
    ) -> bool {
        self.applications
            .get(&scope.application_id)
            .is_some_and(|app| app.actor().configuration.is_revision(revision))
    }

    pub(crate) fn finish_configuration_refresh(
        &mut self,
        scope: &ReadScope,
        meta: ConfigurationRefreshMeta,
        result: Result<crate::configuration::read::ReadOutput, crate::error::CoreError>,
    ) -> Result<Value, Fault> {
        use crate::configuration::policy::configuration_fault;
        let frame = self.frame_limit;
        let catalog = self.providers.as_ref().map_err(|_| Fault::params())?;
        let actor = self
            .applications
            .get_mut(&scope.application_id)
            .filter(|app| app.is_live())
            .ok_or_else(owner_fault)?
            .actor_mut();
        let output = match result {
            Ok(output) => output.into_editor_value(),
            Err(error) => {
                actor.configuration.abandon_refresh(meta.generation);
                return Err(configuration_fault(error));
            }
        };
        if !actor.owns_session(&scope.session_id) {
            actor.configuration.abandon_refresh(meta.generation);
            return Err(owner_fault());
        }
        let staged = actor.configuration.stage_refresh(
            &scope.session_id,
            meta.generation,
            output,
            meta.registry,
            meta.timeout,
            catalog,
            frame,
            std::time::Instant::now(),
        );
        if staged.as_ref().map_or(true, |reply| {
            reply.get("status").and_then(Value::as_str) != Some("prepared")
        }) {
            actor.configuration.abandon_refresh(meta.generation);
        }
        staged.map_err(configuration_fault)
    }

    pub(crate) fn prepare_model_refresh(
        &self,
        params: Value,
    ) -> Result<(RequestScope, ModelCatalogWork), Fault> {
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
                crate::error::CoreError::Unavailable => Fault::new(
                    protocol::error_codes::INVALID_STATE,
                    "Native catalog credential is unavailable",
                    "credential_unavailable",
                ),
                _ => Fault::params(),
            })?;
        Ok((
            connection,
            ModelCatalogWork {
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
        id: Option<&crate::domain::rpc::RpcId>,
    ) -> Dispatch {
        let response_limit = match id.map(|id| id.result_budget(self.frame_limit)).transpose() {
            Ok(limit) => limit.unwrap_or(self.frame_limit),
            Err(_) => {
                return Dispatch {
                    result: Err(Fault::new(
                        protocol::error_codes::RESOURCE_LIMIT,
                        "Response envelope exceeds negotiated frame limit",
                        "resource_limit",
                    )),
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
            return Err(Fault::new(
                protocol::error_codes::INCOMPATIBLE_VERSION,
                "Incompatible protocol version",
                "incompatible_version",
            ));
        }
        self.frame_limit =
            ByteLimit::try_from(init.limits.max_frame_bytes.min(limits::MAX_FRAME_BYTES))
                .map_err(|_| Fault::params())?;
        self.editor_file_snapshot = init
            .capabilities
            .iter()
            .any(|capability| capability == "editor_file_snapshot");
        self.editor_credential_capture = init
            .capabilities
            .iter()
            .any(|capability| capability == "editor_credential_capture");
        self.phase = Phase::Negotiated;
        let capabilities = if self.frame_limit.as_usize() < 2048 {
            protocol::HANDSHAKE_CAPABILITIES
        } else {
            protocol::LIFECYCLE_CAPABILITIES
        };
        Ok(
            json!({"core_version":crate::VERSION, "protocol_major":protocol::MAJOR,
            "protocol_minor":protocol::MINOR, "connection_epoch":self.epoch,
            "capabilities":capabilities,
            "capability_set": 1,
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
            methods::CAPABILITIES_LIST => capabilities_page(params),
            methods::PROVIDER_CATALOG if empty_params(&params) => self
                .providers
                .as_ref()
                .map(crate::providers::ProviderCatalog::snapshot)
                .map_err(|_| {
                    Fault::new(
                        protocol::error_codes::INVALID_STATE,
                        "Provider manifest is invalid",
                        "invalid_catalog",
                    )
                }),
            methods::PROVIDER_CATALOG => {
                let request: CatalogPageRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let catalog = self.providers.as_ref().map_err(|_| {
                    Fault::new(
                        protocol::error_codes::INVALID_STATE,
                        "Provider manifest is invalid",
                        "invalid_catalog",
                    )
                })?;
                catalog
                    .page(request.offset, response_limit)
                    .map_err(|_| Fault::params())
            }
            methods::PROVIDER_CATALOG_TARGET => self.catalog_target(params),
            methods::PROVIDER_LIST => self.provider_list(params),
            methods::MODEL_LIST => self.model_list(params),
            methods::CONFIGURATION_PARSE => self.configuration_parse(params),
            methods::MENTIONS_PARSE => {
                let request = crate::sensors::mention_rpc::ParseRequest::decode(params)?;
                if !self.matches_epoch(request.epoch()) {
                    return Err(owner_fault());
                }
                request.page(response_limit)
            }
            methods::APPLICATION_CREATE => {
                if !empty_params(&params) {
                    return Err(Fault::params());
                }
                if self.applications.len() >= limits::MAX_APPLICATIONS {
                    return Err(capacity_fault());
                }
                let id = ApplicationId::new();
                let registry = crate::policy::ToolRegistry::standard().map_err(|_| {
                    Fault::new(
                        protocol::error_codes::INVALID_STATE,
                        "Tool manifest is invalid",
                        "invalid_catalog",
                    )
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
            methods::SESSION_RESTORE => {
                let args: SessionRestoreParams =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let app = self
                    .applications
                    .get_mut(&args.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?;
                let actor = app.actor_mut();
                let session_id = match args.session_id {
                    Some(ref id) => {
                        if !actor.owns_session(id) {
                            return Err(owner_fault());
                        }
                        id.clone()
                    }
                    None => actor.create_session(),
                };
                let candidate = crate::application::restore::RestoreCandidate::from_json(
                    &args.candidate,
                    args.expected_root.as_deref(),
                )
                .map_err(restore_fault)?;
                let receipt = actor
                    .restore_session(&session_id, candidate)
                    .map_err(restore_fault)?;
                Ok(receipt.into_json())
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
            methods::SESSION_MODE => {
                let scope: SessionScope =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get(&scope.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor();
                let store = actor
                    .session_mode(&scope.session_id)
                    .map_err(|_| owner_fault())?;
                let available_tools = actor.available_tools_for_mode(store.mode());
                Ok(json!({
                    "revision": store.revision(),
                    "mode": store.mode(),
                    "debug_ready": store.debug_ready(),
                    "available_tools": available_tools,
                }))
            }
            methods::SESSION_MODE_COMMIT => {
                let request: ModeCommit =
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
                let intent = super::mode::ModeIntent::new(request.mode, request.debug_ready);
                let (revision, mode, debug_ready) = {
                    let store = actor
                        .commit_session_mode(&request.session_id, request.expected_revision, intent)
                        .map_err(mode_fault)?;
                    (store.revision(), store.mode(), store.debug_ready())
                };
                let available_tools = actor.available_tools_for_mode(mode);
                Ok(json!({
                    "revision": revision,
                    "mode": mode,
                    "debug_ready": debug_ready,
                    "available_tools": available_tools,
                }))
            }
            methods::SESSION_PLAN => {
                let query: PlanQuery =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get(&query.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor();
                if !actor.owns_session(&query.session_id) {
                    return Err(owner_fault());
                }
                let plan = match query.plan_id {
                    Some(ref id) => actor.session_plan_by_id(&query.session_id, id),
                    None => actor.session_plan(&query.session_id),
                };
                Ok(json!({ "plan": plan }))
            }
            methods::SESSION_PLAN_CREATE => {
                let request: PlanCreateRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let text = super::plan::PlanText::try_new(request.text).map_err(plan_fault)?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                let plan = actor
                    .create_session_plan(&request.session_id, text)
                    .map_err(plan_fault)?;
                Ok(json!({ "plan": plan }))
            }
            methods::SESSION_PLAN_REVISE => {
                let request: PlanReviseRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let text = super::plan::PlanText::try_new(request.text).map_err(plan_fault)?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                let intent = super::plan::PlanReviseIntent::new(request.expected_revision, text);
                let plan = actor
                    .revise_session_plan(&request.session_id, &request.plan_id, intent)
                    .map_err(plan_fault)?;
                Ok(json!({ "plan": plan }))
            }
            methods::SESSION_PLAN_CLAIM => {
                let request: PlanClaimRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                let intent = super::plan::PlanClaimIntent::new(
                    request.expected_revision,
                    request.expected_hash,
                );
                let plan = actor
                    .claim_session_plan(&request.session_id, &request.plan_id, intent)
                    .map_err(plan_fault)?;
                Ok(json!({ "claimed": true, "plan": plan }))
            }
            methods::SESSION_PLAN_COMPLETE => {
                let request: PlanCompleteRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                let state = actor
                    .complete_session_plan(&request.session_id, &request.plan_id, request.success)
                    .map_err(plan_fault)?;
                Ok(json!({ "state": state }))
            }
            methods::SESSION_PLAN_REJECT => {
                let request: PlanRejectRequest =
                    serde_json::from_value(params).map_err(|_| Fault::params())?;
                let actor = self
                    .applications
                    .get_mut(&request.application_id)
                    .filter(|app| app.is_live())
                    .ok_or_else(owner_fault)?
                    .actor_mut();
                let state = actor
                    .reject_session_plan(
                        &request.session_id,
                        &request.plan_id,
                        request.expected_revision,
                    )
                    .map_err(plan_fault)?;
                Ok(json!({ "rejected": true, "state": state }))
            }
            _ => Err(Fault::new(
                protocol::error_codes::METHOD_NOT_FOUND,
                "Method not found",
                "unavailable",
            )),
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
        let catalog = self.providers.as_ref().map_err(|_| {
            Fault::new(
                protocol::error_codes::INVALID_STATE,
                "Provider manifest is invalid",
                "invalid_catalog",
            )
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
        let (config_revision, configured_profiles) = app
            .and_then(|app| {
                let view = app.actor().configuration.published_view()?;
                let rev = view.get("revision").and_then(Value::as_u64).unwrap_or(0);
                let profiles = view
                    .get("profiles")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                Some((rev, profiles))
            })
            .unwrap_or((0, Vec::new()));

        let mut seen = std::collections::BTreeSet::new();
        let mut items = Vec::new();

        // 1. Process configured profiles first
        for profile in &configured_profiles {
            if let Some(item) = provider_profile_item(profile, catalog, config_revision) {
                let p_id = item
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                if seen.insert(p_id) {
                    items.push(item);
                }
            }
        }

        let auth_only = req.authenticated_only.unwrap_or(false);

        // 2. Add embedded definitions not yet seen if authenticated_only is false
        if !auth_only {
            for def in catalog.definitions() {
                if seen.insert(def.id().as_str().to_string()) {
                    items.push(provider_embedded_item(def, config_revision));
                }
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
            "config_revision": config_revision,
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

fn provider_profile_item(
    profile: &Value,
    catalog: &ProviderCatalog,
    config_revision: u64,
) -> Option<Value> {
    let p_id = profile.get("provider").and_then(|v| v.as_str())?;
    let api_p_id = ApiProviderId::try_from(p_id.to_string()).ok()?;
    let embedded_def = catalog.get(&api_p_id);
    let name = profile
        .get("name")
        .and_then(|v| v.as_str())
        .map(String::from)
        .or_else(|| embedded_def.map(|d| d.name().as_str().to_string()))
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
    let is_configured = cred_source == "configuration"
        || cred_source == "environment"
        || cred_source == "global"
        || profile
            .get("configured_model")
            .and_then(|v| v.as_str())
            .is_some();
    let is_app_backend = profile
        .get("kind")
        .and_then(|v| v.as_str())
        .is_some_and(|k| k == "application")
        || profile.get("backend").is_some()
        || matches!(p_id, "codex" | "antigravity" | "claude-code");
    let namespace = if is_app_backend {
        "application"
    } else if embedded_def.is_some() {
        if is_configured { "api" } else { "embedded" }
    } else {
        "custom"
    };
    let (readiness, availability) = if authenticated {
        ("ready", "ready")
    } else {
        ("available", "available")
    };
    Some(json!({
        "id": p_id,
        "name": name,
        "namespace": namespace,
        "readiness": readiness,
        "availability": availability,
        "status": status,
        "authenticated": authenticated,
        "config_revision": config_revision,
        "default_model": default_model,
        "models": models,
        "local": is_local,
    }))
}

fn provider_embedded_item(
    def: &crate::providers::ProviderDefinition,
    config_revision: u64,
) -> Value {
    let p_id = def.id().as_str();
    let is_local = def.local();
    let authenticated = is_local || def.keyless();
    let status = if is_local {
        "local"
    } else if authenticated {
        "configured"
    } else {
        "available"
    };
    let (readiness, availability) = if authenticated {
        ("ready", "ready")
    } else {
        ("available", "available")
    };
    json!({
        "id": p_id,
        "name": def.name().as_str(),
        "namespace": "embedded",
        "readiness": readiness,
        "availability": availability,
        "status": status,
        "authenticated": authenticated,
        "config_revision": config_revision,
        "default_model": null,
        "models": Vec::<String>::new(),
        "local": is_local,
    })
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
    Fault::new(
        protocol::error_codes::INVALID_STATE,
        "Invalid connection state",
        "invalid_state",
    )
}
fn owner_fault() -> Fault {
    Fault::new(
        protocol::error_codes::STALE_OWNER,
        "Unknown or foreign owner",
        "stale_owner",
    )
}
fn selection_fault(error: crate::error::CoreError) -> Fault {
    match error {
        crate::error::CoreError::Busy => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "Active work owns the selection",
            "busy",
        ),
        crate::error::CoreError::StaleOwner => Fault::new(
            protocol::error_codes::STALE_OWNER,
            "Selection revision or owner is stale",
            "stale_revision",
        ),
        _ => owner_fault(),
    }
}
fn mode_fault(error: crate::error::CoreError) -> Fault {
    match error {
        crate::error::CoreError::Busy => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "Active work owns the mode",
            "busy",
        ),
        crate::error::CoreError::StaleOwner => Fault::new(
            protocol::error_codes::STALE_OWNER,
            "Mode revision or owner is stale",
            "stale_revision",
        ),
        crate::error::CoreError::Unavailable => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "Debugger preparation failed or unverified",
            "debug_refusal",
        ),
        _ => owner_fault(),
    }
}
fn plan_fault(error: crate::error::CoreError) -> Fault {
    match error {
        crate::error::CoreError::AlreadyCompleted => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "This plan was already decided",
            "already_decided",
        ),
        crate::error::CoreError::StaleOwner => Fault::new(
            protocol::error_codes::STALE_OWNER,
            "Plan revision, hash or owner is stale",
            "stale_revision",
        ),
        crate::error::CoreError::Busy => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "Active work owns the plan",
            "busy",
        ),
        crate::error::CoreError::InvalidValue { .. } => Fault::params(),
        crate::error::CoreError::Limit => capacity_fault(),
        _ => owner_fault(),
    }
}
fn restore_fault(error: crate::error::CoreError) -> Fault {
    match error {
        crate::error::CoreError::Busy => Fault::new(
            protocol::error_codes::INVALID_STATE,
            "Session restore locked by active run or preparation",
            "busy",
        ),
        crate::error::CoreError::StaleOwner => owner_fault(),
        crate::error::CoreError::WorkspaceChanged => Fault::new(
            protocol::error_codes::REJECTED,
            "Candidate project root incompatible with target",
            "root_mismatch",
        ),
        crate::error::CoreError::Limit => capacity_fault(),
        _ => Fault::params(),
    }
}
fn capacity_fault() -> Fault {
    Fault::new(
        protocol::error_codes::RESOURCE_LIMIT,
        "Resource limit reached",
        "resource_limit",
    )
}

fn capabilities_page(params: Value) -> Result<Value, Fault> {
    let offset = params.get("offset").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    let total = protocol::LIFECYCLE_CAPABILITIES.len();
    let end = (offset + protocol::CAPABILITY_PAGE_ITEMS).min(total);
    let slice = protocol::LIFECYCLE_CAPABILITIES
        .get(offset..end)
        .unwrap_or(&[]);
    let complete = end >= total;
    Ok(json!({
        "capabilities": slice,
        "offset": offset,
        "next_offset": end,
        "total": total,
        "complete": complete,
    }))
}
