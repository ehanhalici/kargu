//! A single mailbox writer owns API admission, publication and drained release.

mod admission;
mod budget;
mod circuit;
mod retry;
mod worker;
use super::pending::PendingRequests;
use super::protocol::{self, Fault, RpcId};
use crate::constants::limits;
use crate::{
    api::{ApiError, HttpRequest},
    application::budget::ObservedUsage,
    application::host::{Host, ReadScope},
    error::CoreError,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use tokio::{sync::mpsc, task::JoinSet};
use tokio_util::sync::{CancellationToken, DropGuard};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    scope: ReadScope,
    arguments: HttpRequest,
    #[serde(default)]
    budget: Option<budget::BudgetRef>,
    #[serde(default)]
    retry: Option<retry::Configuration>,
}
struct Pending {
    scope: ReadScope,
    cancel: CancellationToken,
    published: bool,
    terminal: Option<ApiError>,
    charge: Option<budget::Charge>,
    budget_id: Option<crate::domain::BudgetId>,
    retry: Option<retry::Operation>,
    snapshot: Option<Value>,
    circuit: Option<circuit::Grant>,
}
struct Event {
    id: RpcId,
    value: EventValue,
}
enum EventValue {
    Delta(Value),
    Body(String),
}

enum Ready {
    Event(Event),
    Completed(RpcId, Completion),
}
enum Completion {
    Attempt(Outcome),
    Backoff(Result<(), ApiError>),
    Observed(Result<bool, ApiError>),
}
struct Outcome {
    result: Result<Value, ApiError>,
    usage: ObservedUsage,
    entropy: Option<Result<crate::api::resilience::RetryEntropy, CoreError>>,
}

pub(super) struct ApiRequests {
    pending: HashMap<RpcId, Pending>,
    workers: JoinSet<(RpcId, Completion)>,
    sender: mpsc::Sender<Event>,
    events: mpsc::Receiver<Event>,
    ready: VecDeque<Ready>,
    root: CancellationToken,
    _guard: DropGuard,
    budgets: budget::Budgets,
    sequence: crate::domain::RequestSequence,
    circuits: circuit::Circuits,
}
impl Default for ApiRequests {
    fn default() -> Self {
        let root = CancellationToken::new();
        let (sender, events) = mpsc::channel(limits::API_EVENTS);
        Self {
            pending: HashMap::new(),
            workers: JoinSet::new(),
            sender,
            events,
            ready: VecDeque::with_capacity(limits::API_EVENTS.saturating_add(1)),
            _guard: root.clone().drop_guard(),
            root,
            budgets: budget::Budgets::default(),
            sequence: crate::domain::RequestSequence::ZERO,
            circuits: circuit::Circuits::default(),
        }
    }
}
impl ApiRequests {
    pub fn owns_application(&self, id: &crate::domain::ApplicationId) -> bool {
        self.budgets.owns_application(id)
            || self.circuits.owns_application(id)
            || self
                .pending
                .values()
                .any(|pending| &pending.scope.application_id == id)
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.pending.contains_key(id) || self.budgets.contains(id)
    }
    pub fn is_empty(&self) -> bool {
        self.workers.is_empty()
            && self.pending.is_empty()
            && self.ready.is_empty()
            && !self.budgets.closing()
    }
    pub fn budget_rpc(
        &mut self,
        host: &Host,
        method: &str,
        id: RpcId,
        params: Value,
    ) -> Result<Option<Value>, Fault> {
        let pending = &self.pending;
        self.budgets.rpc(host, method, id, params, |application| {
            pending
                .values()
                .any(|request| &request.scope.application_id == application)
        })
    }
    pub fn collect(&mut self, host: &Host) -> Vec<Value> {
        self.circuits.collect(host);
        let pending = &self.pending;
        let replies = self.budgets.collect(host, |id| {
            pending
                .values()
                .any(|request| request.budget_id.as_ref() == Some(id))
        });
        self.sweep(host);
        replies
    }
    pub fn circuit_rpc(
        &mut self,
        host: &Host,
        method: &str,
        params: Value,
    ) -> Result<Value, Fault> {
        self.circuits.rpc(host, method, params)
    }
    pub fn start(&mut self, host: &Host, id: RpcId, params: Value) -> Result<(), Fault> {
        let request: Request = serde_json::from_value(params).map_err(|_| Fault::params())?;
        let admission::Admitted {
            scope,
            arguments,
            charge,
            retry,
            circuit,
            page_bytes,
        } = self.admit_request(host, request)?;
        let deadline = charge.as_ref().map(|charge| charge.deadline);
        let budget_id = charge.as_ref().map(|charge| charge.id.clone());
        let cancel = self.root.child_token();
        let observe_entropy = retry.is_some();
        let expectation = if circuit.is_some() {
            worker::ResponseExpectation::Model
        } else {
            worker::ResponseExpectation::Raw
        };
        self.pending.insert(
            id.clone(),
            Pending {
                scope,
                cancel: cancel.clone(),
                published: false,
                terminal: None,
                charge,
                budget_id,
                retry,
                snapshot: None,
                circuit,
            },
        );
        self.workers.spawn(
            worker::Attempt {
                id,
                arguments,
                sender: self.sender.clone(),
                cancel,
                deadline,
                page_bytes,
                observe_entropy,
                expectation,
            }
            .run(),
        );
        Ok(())
    }
    pub fn cancel(&mut self, id: &RpcId) {
        self.budgets.cancel_waiter(id);
        if let Some(pending) = self.pending.get(id) {
            pending.cancel.cancel();
        }
    }
    pub fn cancel_all(&mut self) {
        self.root.cancel();
    }
    pub fn sweep(&mut self, host: &Host) {
        for pending in self.pending.values() {
            if !host.owns_read_scope(&pending.scope)
                || pending
                    .budget_id
                    .as_ref()
                    .is_some_and(|id| self.budgets.revoked(id))
            {
                pending.cancel.cancel();
            }
        }
    }
    pub async fn next(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
    ) -> Result<Option<Value>, CoreError> {
        if let Some(ready) = self.ready.pop_front() {
            return self.deliver(host, reverse, ready);
        }
        tokio::select! {
            biased;
            completion = self.workers.join_next(), if !self.workers.is_empty() => {
                let (id,result) = completion.ok_or(CoreError::CleanupFailed)?.map_err(|_| CoreError::CleanupFailed)?;
                // All events from this joined worker were enqueued before join.
                // Capture the finite FIFO prefix, then its terminal barrier. New
                // foreign events cannot extend this batch or starve collection.
                let prefix = self.events.len();
                for _ in 0..prefix {
                    let event = self.events.try_recv().map_err(|_|CoreError::CleanupFailed)?;
                    self.ready.push_back(Ready::Event(event));
                }
                self.ready.push_back(Ready::Completed(id,result));
                let ready = self.ready.pop_front().ok_or(CoreError::CleanupFailed)?;
                self.deliver(host,reverse,ready)
            }
            event = self.events.recv() => {
                let event=event.ok_or(CoreError::CleanupFailed)?;
                self.deliver(host,reverse,Ready::Event(event))
            }
        }
    }
    fn deliver(
        &mut self,
        host: &Host,
        reverse: &mut PendingRequests,
        ready: Ready,
    ) -> Result<Option<Value>, CoreError> {
        match ready {
            Ready::Event(event) => {
                let Some(pending) = self.pending.get_mut(&event.id) else {
                    return Ok(None);
                };
                if pending.cancel.is_cancelled() || !host.owns_read_scope(&pending.scope) {
                    return Ok(None);
                }
                if pending
                    .charge
                    .as_ref()
                    .is_some_and(|charge| charge.deadline.expired())
                {
                    pending.terminal = Some(ApiError::RunDeadline);
                    pending.cancel.cancel();
                    return Ok(None);
                }
                let notification = match event.value {
                    EventValue::Delta(value) => {
                        pending.published = true;
                        json!({"jsonrpc":"2.0","method":"api/delta","params":{"request_id":event.id.value(),"delta":value}})
                    }
                    EventValue::Body(chunk) => {
                        json!({"jsonrpc":"2.0","method":"api/body","params":{"request_id":event.id.value(),"chunk":chunk}})
                    }
                };
                if notification.to_string().len().saturating_add(1) > host.frame_limit().as_usize()
                {
                    pending.terminal = Some(ApiError::Limit);
                    pending.cancel.cancel();
                    return Ok(None);
                }
                Ok(Some(notification))
            }
            Ready::Completed(id, outcome) => {
                let pending = self.pending.remove(&id).ok_or(CoreError::CleanupFailed)?;
                self.completed(host, reverse, id, pending, outcome)
            }
        }
    }
    pub async fn drain(&mut self) -> Result<(), CoreError> {
        self.cancel_all();
        self.events.close();
        while let Some(result) = self.workers.join_next().await {
            let (id, outcome) = result.map_err(|_| CoreError::CleanupFailed)?;
            self.collect_usage(&id, outcome)?;
        }
        while let Some(ready) = self.ready.pop_front() {
            if let Ready::Completed(id, outcome) = ready {
                self.collect_usage(&id, outcome)?;
            }
        }
        for pending in self.pending.values_mut() {
            if let Some(charge) = pending.charge.take() {
                self.budgets.finish(charge, ObservedUsage::default())?;
            }
            if let Some(grant) = pending.circuit.take() {
                self.circuits.finish(grant, None)?;
            }
        }
        self.pending.clear();
        self.ready.clear();
        while self.events.try_recv().is_ok() {}
        Ok(())
    }
    fn collect_usage(&mut self, id: &RpcId, completion: Completion) -> Result<(), CoreError> {
        if let Completion::Attempt(outcome) = completion
            && let Some(pending) = self.pending.get_mut(id)
            && let Some(charge) = pending.charge.take()
        {
            self.budgets.finish(charge, outcome.usage)?;
        }
        Ok(())
    }
}

async fn publish_body(
    sender: &mpsc::Sender<Event>,
    id: &RpcId,
    value: Value,
    cancel: &CancellationToken,
    page_bytes: crate::domain::ApiPageBytes,
) -> Result<Value, ApiError> {
    let body = value.to_string();
    if body.len() > 8 * 1024 * 1024 {
        return Err(ApiError::Limit);
    }
    let publish = async {
        let mut offset = 0usize;
        while offset < body.len() {
            let end = body
                .floor_char_boundary(offset.saturating_add(page_bytes.as_usize()).min(body.len()));
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

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    #[tokio::test]
    async fn minimum_page_capacity_publishes_unicode_without_loss() -> TestResult {
        let (sender, mut receiver) = mpsc::channel(limits::API_EVENTS);
        let page = crate::domain::ApiPageBytes::try_from(crate::domain::ByteLimit::try_from(536)?)?;
        let id = RpcId::parse(&json!("unicode-page")).ok_or("id")?;
        let value = json!({"text":"🦀aé"});
        let result =
            publish_body(&sender, &id, value.clone(), &CancellationToken::new(), page).await?;
        assert_eq!(result, json!({"body_ready":true}));
        drop(sender);
        let mut body = String::new();
        while let Some(event) = receiver.recv().await {
            let EventValue::Body(chunk) = event.value else {
                return Err("unexpected delta".into());
            };
            assert!(chunk.len() <= page.as_usize());
            body.push_str(&chunk);
        }
        assert_eq!(serde_json::from_str::<Value>(&body)?, value);
        Ok(())
    }
    #[tokio::test]
    async fn continuous_foreign_deltas_cannot_starve_join_or_overtake_body() -> TestResult {
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"api-fairness","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result.map_err(|_|"initialize")?;
        host.dispatch("initialized", json!({}), false)
            .result
            .map_err(|_| "initialized")?;
        let mut api = ApiRequests::default();
        let first = RpcId::parse(&json!("first")).ok_or("id")?;
        let foreign = RpcId::parse(&json!("foreign")).ok_or("id")?;
        for id in [&first, &foreign] {
            let app = host
                .dispatch("application/create", json!({}), true)
                .result
                .map_err(|_| "application")?;
            let scope = host
                .dispatch("session/create", app, true)
                .result
                .map_err(|_| "session")?;
            api.pending.insert(
                id.clone(),
                Pending {
                    scope: serde_json::from_value(scope)?,
                    cancel: api.root.child_token(),
                    published: false,
                    terminal: None,
                    charge: None,
                    budget_id: None,
                    retry: None,
                    snapshot: None,
                    circuit: None,
                },
            );
        }
        api.sender
            .send(Event {
                id: first.clone(),
                value: EventValue::Body("{}".into()),
            })
            .await?;
        for _ in 1..limits::API_EVENTS {
            api.sender
                .send(Event {
                    id: foreign.clone(),
                    value: EventValue::Delta(json!({"text":"x"})),
                })
                .await?;
        }
        let sender = api.sender.clone();
        let stop = api.root.clone();
        let flood = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _=stop.cancelled()=>break,
                    result=sender.send(Event{id:foreign.clone(),value:EventValue::Delta(json!({"text":"x"}))})=>{
                        if result.is_err() { break; }
                    }
                }
            }
        });
        let completed = first.clone();
        api.workers.spawn(async move {
            (
                completed,
                Completion::Attempt(Outcome {
                    result: Ok(json!({"body_ready":true})),
                    usage: ObservedUsage::default(),
                    entropy: None,
                }),
            )
        });
        tokio::task::yield_now().await;
        let mut body = false;
        let mut terminal = false;
        let mut reverse = PendingRequests::default();
        for _ in 0..limits::API_EVENTS.saturating_add(2) {
            if let Some(reply) = api.next(&host, &mut reverse).await? {
                if reply["method"] == "api/body" && reply["params"]["request_id"] == first.value() {
                    body = true;
                }
                if reply["id"] == first.value() {
                    terminal = body;
                    break;
                }
            }
            // Let the adversarial producer keep its event queue permanently full.
            tokio::task::yield_now().await;
        }
        api.drain().await?;
        flood.await?;
        assert!(
            terminal,
            "A completed attempt was starved or overtook its body"
        );
        Ok(())
    }
}
