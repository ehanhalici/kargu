//! Single-writer application/session lifecycle host for migration stage one.

use crate::application::ApplicationActor;
use crate::constants::{
    limits,
    protocol::{self, methods},
};
use crate::domain::{ApplicationId, ByteLimit, RequestScope, SessionId};
use crate::ipc::protocol::Fault;
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

impl Default for Host {
    fn default() -> Self {
        Self::new()
    }
}

impl Host {
    /// Start a host with a fresh, non-reusable connection epoch.
    pub fn new() -> Self {
        Self {
            epoch: uuid::Uuid::new_v4().to_string(),
            phase: Phase::Fresh,
            frame_limit: ByteLimit::WIRE_MAX,
            applications: HashMap::new(),
            providers: crate::providers::ProviderCatalog::embedded(),
        }
    }

    /// Negotiated limit applied immediately after initialize.
    pub fn frame_limit(&self) -> ByteLimit {
        self.frame_limit
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

    pub(crate) fn matches_epoch(&self, scope: &RequestScope) -> bool {
        scope.as_str() == self.epoch
    }
    pub(crate) fn request_scope(&self) -> Result<RequestScope, crate::error::CoreError> {
        RequestScope::try_from(self.epoch.clone())
    }

    /// Dispatch a request or notification; state-changing methods require ids.
    pub fn dispatch(&mut self, method: &str, params: Value, request: bool) -> Dispatch {
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
            self.ready_call(method, params)
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
        self.phase = Phase::Negotiated;
        Ok(
            json!({"core_version":crate::VERSION, "protocol_major":protocol::MAJOR,
            "protocol_minor":protocol::MINOR, "connection_epoch":self.epoch,
            "capabilities":protocol::LIFECYCLE_CAPABILITIES,
            "limits":{"max_frame_bytes":self.frame_limit,"max_pending_requests":limits::MAX_PENDING}}),
        )
    }

    fn ready_call(&mut self, method: &str, params: Value) -> Result<Value, Fault> {
        match method {
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
            methods::PROVIDER_CATALOG => Err(Fault::params()),
            methods::APPLICATION_CREATE => {
                if !empty_params(&params) {
                    return Err(Fault::params());
                }
                if self.applications.len() >= limits::MAX_APPLICATIONS {
                    return Err(capacity_fault());
                }
                let id = ApplicationId::new();
                self.applications.insert(
                    id.clone(),
                    Application::Live(ApplicationActor::new(id.clone())),
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
                    Ok(
                        json!({"connection_epoch":self.epoch,"application_id":scope.application_id,
                        "session_id":scope.session_id,"generation":0,"sequence":0,
                        "state":"idle","active_run":null}),
                    )
                }
            }
            _ => Err(Fault {
                code: protocol::error_codes::METHOD_NOT_FOUND,
                message: "Method not found",
                status: "unavailable",
            }),
        }
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
fn capacity_fault() -> Fault {
    Fault {
        code: protocol::error_codes::RESOURCE_LIMIT,
        message: "Resource limit reached",
        status: "resource_limit",
    }
}
