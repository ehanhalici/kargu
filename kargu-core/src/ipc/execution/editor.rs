//! Actual prepared editor admission, sharing Commands' gate and the actor's run ledger.
use crate::{
    application::{
        RunHandle,
        host::{Host, ReadScope},
    },
    constants::limits,
    domain::{ApplicationId, ToolCallId, ToolName},
    edit::{
        prepare::{ClaimedAction, PreparationId},
        types::{EditorEditId, EditorRevision, EditorSourceId},
    },
    error::CoreError,
    ipc::protocol::{self, Fault, RpcId},
    security::{
        AuthorizedEditorEdit, EditorAdmission, EditorAdmissionInput, EditorApprovalRequest,
        EditorDecision, EditorPresenter, ExecutionGate, ToolRegistry,
    },
};
use futures_util::FutureExt;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, time::Instant};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request<T> {
    scope: ReadScope,
    arguments: T,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Authorize {
    origin_id: EditorSourceId,
    preparation_id: PreparationId,
    presenter: EditorPresenter,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Decision {
    origin_id: EditorSourceId,
    edit_id: EditorEditId,
    revision: EditorRevision,
    decision: EditorDecision,
}
struct Preparing {
    request_id: RpcId,
    task: JoinHandle<Result<ClaimedAction, CoreError>>,
    cancel: CancellationToken,
    presenter: EditorPresenter,
}
enum Stage {
    Preparing(Preparing),
    Review {
        run: RunHandle,
        request: EditorApprovalRequest,
    },
    Authorized {
        run: RunHandle,
        grant: AuthorizedEditorEdit,
    },
}
struct Operation {
    scope: ReadScope,
    origin: EditorSourceId,
    preparation: PreparationId,
    terminal: Option<CoreError>,
    stage: Stage,
}
#[derive(Default)]
pub(super) struct Editors {
    operations: HashMap<EditorEditId, Operation>,
}
impl Editors {
    pub(super) fn preparing_count(&self) -> usize {
        self.operations
            .values()
            .filter(|op| matches!(op.stage, Stage::Preparing(_)))
            .count()
    }
    pub(super) fn is_empty(&self) -> bool {
        self.operations.is_empty()
    }
    pub(super) fn owns_application(&self, id: &ApplicationId) -> bool {
        self.operations
            .values()
            .any(|op| &op.scope.application_id == id)
    }
    pub(super) fn contains(&self, id: &RpcId) -> bool {
        self.operations
            .values()
            .any(|op| matches!(&op.stage, Stage::Preparing(p) if &p.request_id == id))
    }
    pub(super) fn cancel(&mut self, id: &RpcId) {
        for op in self.operations.values_mut() {
            if let Stage::Preparing(p) = &op.stage
                && &p.request_id == id
            {
                op.terminal = Some(CoreError::Cancelled);
                p.cancel.cancel();
            }
        }
    }
    pub(super) fn cancel_all(&mut self) {
        for op in self.operations.values_mut() {
            op.terminal = Some(CoreError::Cancelled);
            if let Stage::Preparing(p) = &op.stage {
                p.cancel.cancel();
            }
        }
    }
    pub(super) fn authorize(
        &mut self,
        host: &mut Host,
        id: RpcId,
        params: Value,
    ) -> Result<(), Fault> {
        let request: Request<Authorize> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        if self.operations.len() >= limits::MAX_PENDING || self.contains(&id) {
            return Err(fault(CoreError::Limit));
        }
        let actor = host.actor_mut(&request.scope).map_err(fault)?;
        let work = actor.edits.claim(&request.scope.session_id, json!({"origin_id":request.arguments.origin_id,"preparation_id":request.arguments.preparation_id}), Instant::now()).map_err(fault)?;
        let preparation = work.id.clone();
        let origin = work.origin.clone();
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let task = tokio::task::spawn_blocking(move || work.execute(&worker_cancel));
        self.operations.insert(
            EditorEditId::new(),
            Operation {
                scope: request.scope,
                origin,
                preparation,
                terminal: None,
                stage: Stage::Preparing(Preparing {
                    request_id: id,
                    task,
                    cancel,
                    presenter: request.arguments.presenter,
                }),
            },
        );
        Ok(())
    }
    pub(super) fn decision(
        &mut self,
        host: &mut Host,
        gate: &mut ExecutionGate,
        params: Value,
    ) -> Result<Value, Fault> {
        let request: Request<Decision> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        let input = request.arguments;
        let op = self
            .operations
            .get(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        if op.scope != request.scope || op.origin != input.origin_id {
            return Err(fault(CoreError::StaleOwner));
        }
        let Stage::Review {
            request: review, ..
        } = &op.stage
        else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        if review.revision() != input.revision {
            return Err(fault(CoreError::StaleOwner));
        }
        if !host.actor_mut(&op.scope).map_err(fault)?.edits.claim_live(
            &op.scope.session_id,
            &op.preparation,
            Instant::now(),
        ) {
            return Err(fault(CoreError::Cancelled));
        }
        let op = self
            .operations
            .remove(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        let Stage::Review {
            run,
            request: review,
        } = op.stage
        else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        let actor = host.actor_mut(&op.scope).map_err(fault)?;
        match gate.decide_editor(actor, &run, &review, input.revision, input.decision) {
            Ok(grant) => {
                let op = Operation {
                    stage: Stage::Authorized { run, grant },
                    ..op
                };
                let result = descriptor(&input.edit_id, &op);
                self.operations.insert(input.edit_id, op);
                Ok(result)
            }
            Err(error) => {
                actor.cancel(&run).map_err(fault)?;
                gate.dismiss_run(actor, &run).map_err(fault)?;
                actor.finish(&run).map_err(fault)?;
                actor
                    .edits
                    .release_claim(&op.scope.session_id, &op.preparation)
                    .map_err(fault)?;
                Err(fault(error))
            }
        }
    }
    pub(super) fn tick(
        &mut self,
        host: &mut Host,
        gate: &mut ExecutionGate,
        registry: &ToolRegistry,
    ) -> Result<Vec<Value>, CoreError> {
        let mut replies = Vec::new();
        let ids: Vec<_> = self.operations.keys().cloned().collect();
        for id in ids {
            let mut op = self.operations.remove(&id).ok_or(CoreError::StaleOwner)?;
            if op.terminal.is_none() {
                if !host.owns_read_scope(&op.scope) {
                    op.terminal = Some(CoreError::StaleOwner);
                } else if !host.actor_mut(&op.scope)?.edits.claim_live(
                    &op.scope.session_id,
                    &op.preparation,
                    Instant::now(),
                ) {
                    op.terminal = Some(CoreError::Cancelled);
                }
            }
            match op.stage {
                Stage::Preparing(preparing) => {
                    if op.terminal.is_some() {
                        preparing.cancel.cancel();
                    }
                    if !preparing.task.is_finished() {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Preparing(preparing),
                                ..op
                            },
                        );
                        continue;
                    }
                    let result = preparing
                        .task
                        .now_or_never()
                        .ok_or(CoreError::CleanupFailed)?
                        .map_err(|_| CoreError::CleanupFailed)
                        .and_then(|value| value);
                    let result = if let Some(error) = op.terminal.take() {
                        Err(error)
                    } else {
                        result
                    };
                    let result = result.and_then(|prepared| {
                        let actor = host.actor_mut(&op.scope)?;
                        let run = actor.admit_editor(&op.scope.session_id, prepared.settings)?;
                        let admission = gate.admit_editor(
                            actor,
                            &run,
                            registry,
                            &ToolName::try_from("editor_edit".to_owned())?,
                            EditorAdmissionInput {
                                call_id: ToolCallId::new(),
                                action: prepared.action,
                                presenter: preparing.presenter,
                            },
                        );
                        match admission {
                            Ok(EditorAdmission::Review(request)) => {
                                Ok(Stage::Review { run, request })
                            }
                            Ok(EditorAdmission::Authorized(grant)) => {
                                Ok(Stage::Authorized { run, grant })
                            }
                            Err(error) => {
                                actor.cancel(&run)?;
                                gate.dismiss_run(actor, &run)?;
                                actor.finish(&run)?;
                                Err(error)
                            }
                        }
                    });
                    match result {
                        Ok(stage) => {
                            let op = Operation { stage, ..op };
                            let reply =
                                protocol::success(&preparing.request_id, descriptor(&id, &op));
                            if reply.to_string().len() > host.frame_limit().as_usize() {
                                cleanup(host, gate, op)?;
                                replies.push(
                                    fault(CoreError::Limit).response(Some(&preparing.request_id)),
                                );
                            } else {
                                replies.push(reply);
                                self.operations.insert(id, op);
                            }
                        }
                        Err(error) => {
                            host.actor_mut(&op.scope)?
                                .edits
                                .release_claim(&op.scope.session_id, &op.preparation)?;
                            replies.push(fault(error).response(Some(&preparing.request_id)));
                        }
                    }
                }
                Stage::Review { run, request } => {
                    if op.terminal.is_none() {
                        op.terminal = host.actor_mut(&op.scope)?.validate(&run).err();
                        if tokio::time::Instant::now() >= request.deadline() {
                            op.terminal = Some(CoreError::ApprovalExpired);
                        }
                    }
                    let op = Operation {
                        stage: Stage::Review { run, request },
                        ..op
                    };
                    if op.terminal.is_some() {
                        cleanup(host, gate, op)?;
                    } else {
                        self.operations.insert(id, op);
                    }
                }
                Stage::Authorized { run, grant } => {
                    if op.terminal.is_none() {
                        op.terminal = grant.revalidate(host.actor_mut(&op.scope)?).err();
                    }
                    let op = Operation {
                        stage: Stage::Authorized { run, grant },
                        ..op
                    };
                    if op.terminal.is_some() {
                        cleanup(host, gate, op)?;
                    } else {
                        self.operations.insert(id, op);
                    }
                }
            }
        }
        Ok(replies)
    }
}
fn descriptor(id: &EditorEditId, op: &Operation) -> Value {
    match &op.stage {
        Stage::Review { run, request } => {
            json!({"edit_id":id,"state":"review","scope":run.scope(),"revision":request.revision(),"review_mode":request.review_mode(),"applied":false})
        }
        Stage::Authorized { run, grant } => {
            json!({"edit_id":id,"state":"authorized","scope":run.scope(),"revision":grant.revision(),"review_mode":grant.action().review_mode(),"applied":false})
        }
        Stage::Preparing(_) => Value::Null,
    }
}
fn cleanup(host: &mut Host, gate: &mut ExecutionGate, op: Operation) -> Result<(), CoreError> {
    let actor = host.actor_mut(&op.scope)?;
    match op.stage {
        Stage::Review { run, .. } => {
            actor.cancel(&run)?;
            gate.dismiss_run(actor, &run)?;
            actor.finish(&run)?;
        }
        Stage::Authorized { run, grant } => {
            actor.cancel(&run)?;
            grant.cancel_unissued(actor)?;
            actor.finish(&run)?;
        }
        Stage::Preparing(_) => return Err(CoreError::Busy),
    }
    actor
        .edits
        .release_claim(&op.scope.session_id, &op.preparation)
}
fn fault(error: CoreError) -> Fault {
    crate::edit::prepare::fault(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    #[tokio::test]
    async fn revoked_claim_keeps_preparation_capacity_until_the_actual_worker_joins() -> TestResult
    {
        let root = tempfile::tempdir()?;
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"claim-drain-test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result.map_err(|_|"initialize")?;
        host.dispatch("initialized", json!({}), false)
            .result
            .map_err(|_| "initialized")?;
        let app = host
            .dispatch("application/create", json!({}), true)
            .result
            .map_err(|_| "application")?;
        let scope: ReadScope = serde_json::from_value(
            host.dispatch("session/create", app, true)
                .result
                .map_err(|_| "session")?,
        )?;
        let source = "editor_source_12345678-1234-4234-8234-123456789abc";
        let scoped = |arguments: Value| json!({"scope":{"application_id":scope.application_id,"session_id":scope.session_id},"arguments":arguments});
        let begin = || {
            scoped(
                json!({"origin_id":source,"root":root.path(),"mode":"agent","intent":{"kind":"write","path":"empty","new_bytes":0},"live":null,"config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"buffer_only"}),
            )
        };
        let id = host
            .dispatch("edit/begin", begin(), true)
            .result
            .map_err(|_| "begin")?["preparation_id"]
            .clone();
        let ticket = json!({"origin_id":source,"preparation_id":id});
        let (_, work) = host
            .prepare_edit(scoped(ticket.clone()), false)
            .map_err(|_| "take")?;
        let crate::edit::prepare::PrepareWork::Read(work) = work else {
            return Err("expected file work".into());
        };
        let cancel = CancellationToken::new();
        let result = work.execute(
            &cancel,
            Instant::now()
                .checked_add(Duration::from_secs(3))
                .ok_or("deadline")?,
        );
        let prep_id: PreparationId = serde_json::from_value(id)?;
        host.finish_edit(&scope, &prep_id, result)
            .map_err(|_| "finish prepare")?;
        let claim = host.actor_mut(&scope)?.edits.claim(
            &scope.session_id,
            ticket.clone(),
            Instant::now(),
        )?;
        let preparation = claim.id.clone();
        let origin = claim.origin.clone();
        let (release, wait) = mpsc::channel::<()>();
        let worker_cancel = cancel.clone();
        let task = tokio::task::spawn_blocking(move || {
            wait.recv().map_err(|_| CoreError::Cancelled)?;
            claim.execute(&worker_cancel)
        });
        let request_id = RpcId::String("held-claim".to_owned());
        let mut editors = Editors::default();
        editors.operations.insert(
            EditorEditId::new(),
            Operation {
                scope: scope.clone(),
                origin,
                preparation,
                terminal: None,
                stage: Stage::Preparing(Preparing {
                    request_id: request_id.clone(),
                    task,
                    cancel,
                    presenter: EditorPresenter::Missing,
                }),
            },
        );
        assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
        host.dispatch("edit/abort", scoped(ticket), true)
            .result
            .map_err(|_| "abort")?;
        editors.cancel(&request_id);
        let mut gate = ExecutionGate::default();
        let registry = ToolRegistry::default();
        assert!(editors.tick(&mut host, &mut gate, &registry)?.is_empty());
        assert!(!editors.is_empty());
        assert!(host.dispatch("edit/begin", begin(), true).result.is_err());
        release.send(())?;
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let replies = editors.tick(&mut host, &mut gate, &registry)?;
                if editors.is_empty() {
                    assert_eq!(replies.len(), 1);
                    return Ok::<(), CoreError>(());
                }
                tokio::task::yield_now().await;
            }
        })
        .await??;
        assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
        Ok(())
    }
}
