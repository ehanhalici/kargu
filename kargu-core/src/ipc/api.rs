//! A single mailbox writer owns API admission, publication and drained release.

use super::protocol::{self, Fault, RpcId};
use crate::{
    api::{ApiError, HttpRequest},
    application::host::{Host, ReadScope},
    error::CoreError,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use tokio::{sync::mpsc, task::JoinSet};
use tokio_util::sync::{CancellationToken, DropGuard};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    scope: ReadScope,
    arguments: HttpRequest,
}
struct Pending {
    scope: ReadScope,
    cancel: CancellationToken,
    published: bool,
    terminal: Option<ApiError>,
}
struct Event {
    id: RpcId,
    value: EventValue,
}
enum EventValue {
    Delta(Value),
    Body(String),
}

pub(super) struct ApiRequests {
    pending: HashMap<RpcId, Pending>,
    workers: JoinSet<(RpcId, Result<Value, ApiError>)>,
    sender: mpsc::Sender<Event>,
    events: mpsc::Receiver<Event>,
    root: CancellationToken,
    _guard: DropGuard,
}
impl Default for ApiRequests {
    fn default() -> Self {
        let root = CancellationToken::new();
        let (sender, events) = mpsc::channel(16);
        Self {
            pending: HashMap::new(),
            workers: JoinSet::new(),
            sender,
            events,
            _guard: root.clone().drop_guard(),
            root,
        }
    }
}
impl ApiRequests {
    pub fn contains(&self, id: &RpcId) -> bool {
        self.pending.contains_key(id)
    }
    pub fn is_empty(&self) -> bool {
        self.workers.is_empty()
    }
    pub fn start(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        let request: Request = serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault("stale_owner", "API owner is no longer live"));
        }
        if self.root.is_cancelled() || self.pending.len() >= 8 {
            return Err(fault("resource_limit", "API admission limit reached"));
        }
        let cancel = self.root.child_token();
        self.pending.insert(
            id.clone(),
            Pending {
                scope: request.scope,
                cancel: cancel.clone(),
                published: false,
                terminal: None,
            },
        );
        let sender = self.sender.clone();
        let page_bytes = host
            .frame_limit()
            .as_usize()
            .saturating_sub(512)
            .saturating_div(6)
            .min(32 * 1024);
        self.workers.spawn(async move {
            let event_id = id.clone();
            let event_sender = sender.clone();
            let result = crate::api::execute(
                request.arguments,
                move |value| {
                    let sender = event_sender.clone();
                    let id = event_id.clone();
                    async move {
                        sender
                            .send(Event {
                                id,
                                value: EventValue::Delta(value),
                            })
                            .await
                            .map_err(|_| ApiError::Cancelled)
                    }
                },
                cancel.clone(),
            )
            .await;
            let result = match result {
                Ok(value) => publish_body(&sender, &id, value, &cancel, page_bytes).await,
                Err(error) => Err(error),
            };
            (id, result)
        });
        Ok(())
    }
    pub fn cancel(&mut self, id: &RpcId) {
        if let Some(pending) = self.pending.get(id) {
            pending.cancel.cancel();
        }
    }
    pub fn cancel_all(&mut self) {
        self.root.cancel();
    }
    pub fn sweep(&mut self, host: &Host) {
        for pending in self.pending.values() {
            if !host.owns_read_scope(&pending.scope) {
                pending.cancel.cancel();
            }
        }
    }
    pub async fn next(&mut self, host: &Host) -> Result<Option<Value>, CoreError> {
        // Drain already-enqueued deltas before their terminal response. The shared
        // bounded event channel backpressures producers without blocking Host.
        tokio::select! {
            biased;
            event = self.events.recv() => {
                let Some(event) = event else { return Err(CoreError::CleanupFailed); };
                let Some(pending) = self.pending.get_mut(&event.id) else { return Ok(None); };
                if pending.cancel.is_cancelled() || !host.owns_read_scope(&pending.scope) { return Ok(None); }
                let notification = match event.value {
                    EventValue::Delta(value) => {
                        pending.published = true;
                        json!({"jsonrpc":"2.0","method":"api/delta","params":{"request_id":event.id.value(),"delta":value}})
                    }
                    EventValue::Body(chunk) => json!({"jsonrpc":"2.0","method":"api/body","params":{"request_id":event.id.value(),"chunk":chunk}}),
                };
                if notification.to_string().len().saturating_add(1) > host.frame_limit().as_usize() {
                    pending.terminal = Some(ApiError::Limit);
                    pending.cancel.cancel();
                    return Ok(None);
                }
                Ok(Some(notification))
            }
            completion = self.workers.join_next() => {
                let (id,result) = completion.ok_or(CoreError::CleanupFailed)?.map_err(|_| CoreError::CleanupFailed)?;
                let pending = self.pending.remove(&id).ok_or(CoreError::CleanupFailed)?;
                let result = if let Some(error) = pending.terminal { Err(error) }
                    else if pending.cancel.is_cancelled() || !host.owns_read_scope(&pending.scope) { Err(ApiError::Cancelled) } else { result };
                let payload = match result {
                    Ok(value) => value,
                    Err(error) => json!({"failure":error.snapshot(),"partial":pending.published}),
                };
                Ok(Some(protocol::success(&id,payload)))
            }
        }
    }
    pub async fn drain(&mut self) -> Result<(), CoreError> {
        self.cancel_all();
        while let Some(result) = self.workers.join_next().await {
            let _ = result.map_err(|_| CoreError::CleanupFailed)?;
        }
        self.pending.clear();
        Ok(())
    }
}

async fn publish_body(
    sender: &mpsc::Sender<Event>,
    id: &RpcId,
    value: Value,
    cancel: &CancellationToken,
    page_bytes: usize,
) -> Result<Value, ApiError> {
    let body = value.to_string();
    if body.len() > 8 * 1024 * 1024 || page_bytes == 0 {
        return Err(ApiError::Limit);
    }
    let publish = async {
        let mut offset = 0usize;
        while offset < body.len() {
            let end = body.floor_char_boundary(offset.saturating_add(page_bytes).min(body.len()));
            if end <= offset {
                return Err(ApiError::Limit);
            }
            let chunk = body.get(offset..end).ok_or(ApiError::Protocol)?.to_owned();
            sender
                .send(Event {
                    id: id.clone(),
                    value: EventValue::Body(chunk),
                })
                .await
                .map_err(|_| ApiError::Cancelled)?;
            offset = end;
        }
        Ok(json!({"body_ready":true}))
    };
    tokio::select! {
        biased;
        _=cancel.cancelled()=>Err(ApiError::Cancelled),
        result=tokio::time::timeout(std::time::Duration::from_secs(30),publish)=>result.map_err(|_|ApiError::Limit)?,
    }
}
fn fault(status: &'static str, message: &'static str) -> Fault {
    Fault {
        code: crate::constants::protocol::error_codes::INVALID_STATE,
        message,
        status,
    }
}
