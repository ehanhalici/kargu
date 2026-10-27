//! One mailbox writer owns bounded read admission and completion publication.

use super::protocol::{Fault, RpcId};
use crate::{
    application::host::{Host, ReadScope},
    configuration::read::{ReadInput, ReadOutput},
    constants::{limits, protocol, timeouts},
    domain::RequestScope,
    error::CoreError,
    workspace::{ReadResult, WorkspaceRead},
};
use serde_json::Value;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use tokio::task::JoinSet;
use tokio_util::sync::{CancellationToken, DropGuard};

struct PendingRead {
    scope: ReadOwner,
    cancel: CancellationToken,
    deadline: Instant,
    terminal: Option<CoreError>,
}

enum ReadOwner {
    Session(ReadScope),
    Connection(RequestScope),
}
impl ReadOwner {
    fn is_live(&self, host: &Host) -> bool {
        match self {
            Self::Session(scope) => host.owns_read_scope(scope),
            Self::Connection(scope) => host.owns_connection_read(scope),
        }
    }
}
enum ReadOperation {
    Workspace(WorkspaceRead),
    Configuration(ReadInput),
}
enum ReadCompletion {
    Workspace(ReadResult),
    Configuration(ReadOutput),
}
impl ReadOperation {
    fn timeout(&self) -> Duration {
        match self {
            Self::Workspace(_) => timeouts::WORKSPACE_READ,
            Self::Configuration(input) => input.timeout(),
        }
    }
    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ReadCompletion, CoreError> {
        match self {
            Self::Workspace(input) => input
                .execute(cancel, deadline)
                .map(ReadCompletion::Workspace),
            Self::Configuration(input) => input
                .execute(cancel, deadline)
                .map(ReadCompletion::Configuration),
        }
    }
}
impl ReadCompletion {
    fn into_value(self) -> Result<Value, CoreError> {
        match self {
            Self::Workspace(value) => serde_json::to_value(value).map_err(|_| CoreError::Limit),
            Self::Configuration(value) => Ok(value.into_editor_value()),
        }
    }
}

pub(super) struct ReadTools {
    requests: HashMap<RpcId, PendingRead>,
    workers: JoinSet<(RpcId, Result<ReadCompletion, CoreError>)>,
    root: CancellationToken,
    _cancel_on_drop: DropGuard,
}

impl Default for ReadTools {
    fn default() -> Self {
        let root = CancellationToken::new();
        Self {
            requests: HashMap::new(),
            workers: JoinSet::new(),
            _cancel_on_drop: root.clone().drop_guard(),
            root,
        }
    }
}

impl ReadTools {
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.requests
            .values()
            .any(|pending| matches!(&pending.scope, ReadOwner::Session(scope) if &scope.application_id == id))
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.requests.contains_key(id)
    }
    pub fn is_empty(&self) -> bool {
        self.requests.is_empty()
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

    fn start_owned(
        &mut self,
        id: RpcId,
        scope: ReadOwner,
        input: ReadOperation,
    ) -> Result<(), Fault> {
        if self.root.is_cancelled() {
            return Err(fault(CoreError::Cancelled));
        }
        if self.contains(&id) || self.requests.len() >= limits::READ_WORKERS {
            return Err(fault(CoreError::Limit));
        }
        let cancel = self.root.child_token();
        let deadline = Instant::now()
            .checked_add(input.timeout())
            .ok_or_else(|| fault(CoreError::ArithmeticOverflow))?;
        self.requests.insert(
            id.clone(),
            PendingRead {
                scope,
                cancel: cancel.clone(),
                deadline,
                terminal: None,
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
                } else if Instant::now() >= request.deadline {
                    request.terminal = Some(CoreError::Deadline);
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
        }
    }

    // The select! caller is the only writer. No I/O worker holds a Host reference.
    pub async fn next(&mut self, host: &Host) -> Option<Result<Value, CoreError>> {
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
        } else if Instant::now() >= request.deadline {
            Err(CoreError::Deadline)
        } else {
            result
        };
        Some(Ok(match result {
            Ok(result) => match result.into_value() {
                Ok(value) => super::protocol::success(&id, value),
                Err(_) => fault(CoreError::Limit).response(Some(&id)),
            },
            Err(error) => fault(error).response(Some(&id)),
        }))
    }
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
            while let Some(reply) = tools.next(&host).await {
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
        while let Some(reply) = tools.next(&host).await {
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
                .next(&host)
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
            while let Some(reply) = tools.next(&host).await {
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
        while let Some(reply) = tools.next(&host).await {
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
        while let Some(reply) = tools.next(&host).await {
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
            tools.next(&host).await.ok_or("missing result")??["error"]["data"]["status"],
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
            let reply = tools.next(&host).await.ok_or("missing completion")??;
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
        assert!(tools.next(&host).await.is_none());
        Ok(())
    }
}
