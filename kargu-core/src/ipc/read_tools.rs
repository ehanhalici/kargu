//! One mailbox writer owns bounded read admission and completion publication.

use super::protocol::{Fault, RpcId};
use crate::{
    constants::{limits, protocol, timeouts},
    error::CoreError,
    host::{Host, ReadScope},
    search::{FindFilesInput, FindFilesPlan, FindFilesResult},
};
use serde_json::Value;
use std::{collections::HashMap, time::Instant};
use tokio::task::JoinSet;
use tokio_util::sync::{CancellationToken, DropGuard};

struct PendingRead {
    scope: ReadScope,
    cancel: CancellationToken,
    deadline: Instant,
    terminal: Option<CoreError>,
}

pub(super) struct ReadTools {
    requests: HashMap<RpcId, PendingRead>,
    workers: JoinSet<(RpcId, Result<FindFilesResult, CoreError>)>,
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
        input: FindFilesInput,
    ) -> Result<(), Fault> {
        if self.root.is_cancelled() {
            return Err(fault(CoreError::Cancelled));
        }
        if self.contains(&id) || self.requests.len() >= limits::READ_WORKERS {
            return Err(fault(CoreError::Limit));
        }
        let cancel = self.root.child_token();
        let deadline = Instant::now()
            .checked_add(timeouts::WORKSPACE_READ)
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
            let result = if cancel.is_cancelled() {
                Err(CoreError::Cancelled)
            } else {
                FindFilesPlan::try_from(input).and_then(|plan| plan.execute(&cancel, deadline))
            };
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
                if !host.owns_read_scope(&request.scope) {
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
        } else if !host.owns_read_scope(&request.scope) {
            Err(CoreError::StaleOwner)
        } else if Instant::now() >= request.deadline {
            Err(CoreError::Deadline)
        } else {
            result
        };
        Some(Ok(match result {
            Ok(result) => match serde_json::to_value(result) {
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
            "Invalid search arguments",
            "invalid_params",
        ),
        CoreError::Rejected => (
            codes::REJECTED,
            "Search path is outside the workspace or unsupported",
            "rejected",
        ),
        CoreError::StaleOwner => (
            codes::STALE_OWNER,
            "Search owner is no longer live",
            "stale_owner",
        ),
        CoreError::Cancelled => (codes::CANCELLED, "Search cancelled", "cancelled"),
        CoreError::Deadline => (codes::TIMEOUT, "Search deadline exceeded", "timeout"),
        CoreError::WorkspaceChanged => (
            codes::WORKSPACE_CHANGED,
            "Search workspace changed",
            "workspace_changed",
        ),
        CoreError::Io(_) => (codes::IO, "Search filesystem operation failed", "io_error"),
        _ => (
            codes::RESOURCE_LIMIT,
            "Search resource limit reached",
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

    fn arguments(root: &std::path::Path) -> FindFilesInput {
        FindFilesInput {
            root: root.to_owned(),
            path: None,
            pattern: "*.el".into(),
            skip_directories: vec![],
            max_files: 2000,
            max_directories: 2000,
        }
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
