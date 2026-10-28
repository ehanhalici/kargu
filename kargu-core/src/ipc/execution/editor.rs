//! Actual prepared editor admission, sharing Commands' gate and the actor's run ledger.
mod issue;
use crate::{
    application::{
        RunHandle,
        host::{Host, ReadScope},
    },
    constants::limits,
    domain::{ApplicationId, ToolCallId, ToolName},
    edit::{
        journal::JournalDirectory,
        prepare::{ClaimedAction, PreflightFile, PreflightSet, PreparationId, ReadyPreflight},
        types::{
            EditorEditId, EditorIssueToken, EditorRevision, EditorSourceId, NoDispatchReason,
            QuiescentEffect,
        },
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
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Preflight {
    origin_id: EditorSourceId,
    edit_id: EditorEditId,
    revision: EditorRevision,
    witness: PreflightFile,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Issue {
    origin_id: EditorSourceId,
    edit_id: EditorEditId,
    revision: EditorRevision,
    journal_directory: JournalDirectory,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Quiescent {
    origin_id: EditorSourceId,
    edit_id: EditorEditId,
    revision: EditorRevision,
    issued_token: EditorIssueToken,
    effect: QuiescentEffect,
}
struct Preflighting {
    run: RunHandle,
    grant: AuthorizedEditorEdit,
    task: JoinHandle<Result<ReadyPreflight, CoreError>>,
    cancel: CancellationToken,
    request_id: RpcId,
    deadline: Instant,
}
struct Preparing {
    request_id: RpcId,
    task: JoinHandle<Result<ClaimedAction, CoreError>>,
    cancel: CancellationToken,
    presenter: EditorPresenter,
}
enum Stage {
    Issuing(issue::Recording),
    Issued(Box<issue::Issued>),
    Finishing(issue::Finishing),
    Preparing(Preparing),
    Review {
        run: RunHandle,
        request: EditorApprovalRequest,
    },
    Authorized {
        run: RunHandle,
        grant: AuthorizedEditorEdit,
        witnesses: PreflightSet,
    },
    Preflighting(Preflighting),
    Preflighted {
        run: RunHandle,
        grant: AuthorizedEditorEdit,
        preflight: ReadyPreflight,
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
    disconnected: bool,
}
impl Editors {
    pub(super) fn reserved_workers(&self) -> usize {
        self.operations
            .values()
            .filter(|op| {
                matches!(
                    op.stage,
                    Stage::Preparing(_)
                        | Stage::Preflighting(_)
                        | Stage::Issuing(_)
                        | Stage::Issued(_)
                        | Stage::Finishing(_)
                )
            })
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
        self.operations.values().any(|op| match &op.stage {
            Stage::Preparing(p) => &p.request_id == id,
            Stage::Preflighting(p) => &p.request_id == id,
            Stage::Issuing(p) => &p.request_id == id,
            Stage::Finishing(p) => match &p.completion {
                issue::Completion::Unissued { request_id, .. } => request_id == id,
                issue::Completion::Quiescent { request_id, .. } => request_id.as_ref() == Some(id),
            },
            _ => false,
        })
    }
    pub(super) fn cancel(&mut self, id: &RpcId) {
        for op in self.operations.values_mut() {
            match &op.stage {
                Stage::Preparing(p) if &p.request_id == id => {
                    if op.terminal.is_none() {
                        op.terminal = Some(CoreError::Cancelled);
                    }
                    p.cancel.cancel();
                }
                Stage::Preflighting(p) if &p.request_id == id => {
                    if op.terminal.is_none() {
                        op.terminal = Some(CoreError::Cancelled);
                    }
                    p.cancel.cancel();
                }
                Stage::Issuing(p) if &p.request_id == id => {
                    if op.terminal.is_none() {
                        op.terminal = Some(CoreError::Cancelled);
                    }
                    p.cancel.cancel();
                }
                _ => {}
            }
        }
    }
    pub(super) fn cancel_all(&mut self) {
        for op in self.operations.values_mut() {
            if op.terminal.is_none() {
                op.terminal = Some(CoreError::Cancelled);
            }
            match &op.stage {
                Stage::Preparing(p) => p.cancel.cancel(),
                Stage::Preflighting(p) => p.cancel.cancel(),
                Stage::Issuing(p) => p.cancel.cancel(),
                _ => {}
            }
        }
    }
    pub(super) fn disconnect(&mut self) {
        self.disconnected = true;
        self.cancel_all();
    }
    fn writer_reserved(&self) -> bool {
        self.operations.values().any(|op| {
            matches!(
                op.stage,
                Stage::Issuing(_) | Stage::Issued(_) | Stage::Finishing(_)
            )
        })
    }
    pub(super) fn issue(
        &mut self,
        host: &mut Host,
        id: RpcId,
        params: Value,
        worker_available: bool,
    ) -> Result<(), Fault> {
        let request: Request<Issue> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        if !worker_available || self.writer_reserved() {
            return Err(fault(CoreError::Busy));
        }
        let input = request.arguments;
        let op = self
            .operations
            .get(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        if op.scope != request.scope || op.origin != input.origin_id {
            return Err(fault(CoreError::StaleOwner));
        }
        let Stage::Preflighted { grant, .. } = &op.stage else {
            return Err(fault(CoreError::Rejected));
        };
        if grant.revision() != input.revision {
            return Err(fault(CoreError::StaleOwner));
        }
        let actor = host.actor_mut(&op.scope).map_err(fault)?;
        grant.revalidate(actor).map_err(fault)?;
        let artifact = actor
            .edits
            .claimed_artifact(
                &op.scope.session_id,
                &op.origin,
                &op.preparation,
                Instant::now(),
            )
            .map_err(fault)?;
        let op = self
            .operations
            .remove(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        let Stage::Preflighted {
            run,
            grant,
            preflight,
        } = op.stage
        else {
            return Err(fault(CoreError::Rejected));
        };
        let stage = issue::Recording::start(issue::Start {
            run,
            grant,
            preflight,
            id: input.edit_id.clone(),
            directory: input.journal_directory,
            artifact,
            request_id: id,
        })
        .map_err(fault)?;
        self.operations.insert(
            input.edit_id,
            Operation {
                stage: Stage::Issuing(stage),
                ..op
            },
        );
        Ok(())
    }
    pub(super) fn quiescent(
        &mut self,
        host: &mut Host,
        id: RpcId,
        params: Value,
    ) -> Result<(), Fault> {
        let request: Request<Quiescent> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        let input = request.arguments;
        let op = self
            .operations
            .get(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        // Issued owners may be retired. Correlation still requires their exact original scope/token.
        if op.scope != request.scope || op.origin != input.origin_id {
            return Err(fault(CoreError::StaleOwner));
        }
        let Stage::Issued(issued) = &op.stage else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        if issued.token != input.issued_token || issued.effect.revision() != input.revision {
            return Err(fault(CoreError::StaleOwner));
        }
        host.actor_mut(&op.scope)
            .map_err(fault)?
            .validate_owner(&issued.run)
            .map_err(fault)?;
        let op = self
            .operations
            .remove(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        let Stage::Issued(issued) = op.stage else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        let reason = match op.terminal {
            Some(CoreError::Deadline | CoreError::ApprovalExpired) => NoDispatchReason::Timeout,
            Some(_) => NoDispatchReason::Cancelled,
            None => {
                if Instant::now() >= issued.deadline || issued.run.deadline().expired() {
                    NoDispatchReason::Timeout
                } else {
                    NoDispatchReason::Cancelled
                }
            }
        };
        let finishing = issued
            .finish(Some(id), input.effect, reason)
            .map_err(fault)?;
        self.operations.insert(
            input.edit_id,
            Operation {
                stage: Stage::Finishing(finishing),
                ..op
            },
        );
        Ok(())
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
    pub(super) fn preflight(
        &mut self,
        host: &mut Host,
        id: RpcId,
        params: Value,
        worker_available: bool,
    ) -> Result<Option<Value>, Fault> {
        let request: Request<Preflight> =
            serde_json::from_value(params).map_err(|_| Fault::params())?;
        if !host.owns_read_scope(&request.scope) {
            return Err(fault(CoreError::StaleOwner));
        }
        let input = request.arguments;
        let op = self
            .operations
            .get_mut(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        if op.scope != request.scope || op.origin != input.origin_id {
            return Err(fault(CoreError::StaleOwner));
        }
        let Stage::Authorized {
            grant, witnesses, ..
        } = &mut op.stage
        else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        if grant.revision() != input.revision {
            return Err(fault(CoreError::StaleOwner));
        }
        let actor = host.actor_mut(&op.scope).map_err(fault)?;
        grant.revalidate(actor).map_err(fault)?;
        let artifact = actor
            .edits
            .claimed_artifact(
                &op.scope.session_id,
                &op.origin,
                &op.preparation,
                Instant::now(),
            )
            .map_err(fault)?;
        if witnesses.would_finish(&artifact) && !worker_available {
            return Err(fault(CoreError::Limit));
        }
        let progress = witnesses.record(&artifact, input.witness).map_err(fault)?;
        if !progress.ready {
            return serde_json::to_value(progress)
                .map(Some)
                .map_err(|_| fault(CoreError::InvalidToolOutput));
        }
        let op = self
            .operations
            .remove(&input.edit_id)
            .ok_or_else(|| fault(CoreError::StaleOwner))?;
        let Stage::Authorized {
            run,
            grant,
            witnesses,
        } = op.stage
        else {
            return Err(fault(CoreError::AlreadyCompleted));
        };
        let deadline = Instant::now()
            .checked_add(crate::constants::timeouts::EDIT_PREFLIGHT)
            .ok_or_else(|| fault(CoreError::ArithmeticOverflow))?;
        let work = witnesses.into_work(artifact, deadline).map_err(fault)?;
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let task = tokio::task::spawn_blocking(move || work.execute(&worker_cancel));
        self.operations.insert(
            input.edit_id,
            Operation {
                stage: Stage::Preflighting(Preflighting {
                    run,
                    grant,
                    task,
                    cancel,
                    request_id: id,
                    deadline,
                }),
                ..op
            },
        );
        Ok(None)
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
        host.actor_mut(&op.scope)
            .map_err(fault)?
            .edits
            .claim_status(&op.scope.session_id, &op.preparation, Instant::now())
            .map_err(fault)?;
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
                    stage: Stage::Authorized {
                        run,
                        grant,
                        witnesses: PreflightSet::default(),
                    },
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
                } else {
                    op.terminal = host
                        .actor_mut(&op.scope)?
                        .edits
                        .claim_status(&op.scope.session_id, &op.preparation, Instant::now())
                        .err();
                }
            }
            match op.stage {
                Stage::Issuing(mut recording) => {
                    if op.terminal.is_none() {
                        op.terminal = host.actor_mut(&op.scope)?.validate(&recording.run).err();
                    }
                    if op.terminal.is_none() && Instant::now() >= recording.deadline {
                        op.terminal = Some(CoreError::Deadline);
                    }
                    if op.terminal.is_some() {
                        recording.cancel.cancel();
                    }
                    if !recording.task.is_finished() {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Issuing(recording),
                                ..op
                            },
                        );
                        continue;
                    }
                    let recorded = (&mut recording.task)
                        .now_or_never()
                        .ok_or(CoreError::CleanupFailed)?
                        .map_err(|_| CoreError::CleanupFailed)?;
                    let journal = match recorded.journal {
                        Ok(journal) => journal,
                        Err(error) => {
                            let terminal = op.terminal.take().unwrap_or(error);
                            let timed_out = matches!(
                                terminal,
                                CoreError::Deadline | CoreError::ApprovalExpired
                            );
                            cleanup(
                                host,
                                gate,
                                Operation {
                                    stage: Stage::Authorized {
                                        run: recording.run,
                                        grant: recorded.grant,
                                        witnesses: PreflightSet::default(),
                                    },
                                    terminal: Some(if timed_out {
                                        CoreError::Deadline
                                    } else {
                                        CoreError::Cancelled
                                    }),
                                    ..op
                                },
                            )?;
                            replies.push(fault(terminal).response(Some(&recording.request_id)));
                            continue;
                        }
                    };
                    let actor = host.actor_mut(&op.scope)?;
                    let error = op
                        .terminal
                        .take()
                        .or_else(|| recorded.grant.revalidate(actor).err());
                    if let Some(error) = error {
                        let finishing = issue::Finishing::start(
                            recording.run,
                            journal,
                            issue::Completion::Unissued {
                                grant: recorded.grant,
                                request_id: recording.request_id,
                                error,
                            },
                            crate::edit::journal::JournalResolution::NotDispatched,
                        )?;
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Finishing(finishing),
                                ..op
                            },
                        );
                        continue;
                    }
                    let effect = match recorded.grant.issue(actor) {
                        Ok(effect) => effect,
                        Err(failure) => {
                            let (error, grant) = *failure;
                            let finishing = issue::Finishing::start(
                                recording.run,
                                journal,
                                issue::Completion::Unissued {
                                    grant,
                                    request_id: recording.request_id,
                                    error,
                                },
                                crate::edit::journal::JournalResolution::NotDispatched,
                            )?;
                            self.operations.insert(
                                id,
                                Operation {
                                    stage: Stage::Finishing(finishing),
                                    ..op
                                },
                            );
                            continue;
                        }
                    };
                    let issued = Box::new(issue::Issued {
                        run: recording.run,
                        token: recording.token,
                        effect,
                        journal,
                        preflight: recorded.preflight,
                        deadline: Instant::now()
                            .checked_add(crate::constants::timeouts::EDIT_RECEIPT)
                            .ok_or(CoreError::ArithmeticOverflow)?,
                        revoked: false,
                    });
                    let reply = protocol::success(&recording.request_id, issued.descriptor(&id));
                    if reply.to_string().len() > host.frame_limit().as_usize() {
                        let finishing = issued.finish(
                            None,
                            QuiescentEffect::NotDispatched,
                            NoDispatchReason::Cancelled,
                        )?;
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Finishing(finishing),
                                ..op
                            },
                        );
                        replies.push(fault(CoreError::Limit).response(Some(&recording.request_id)));
                    } else {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Issued(issued),
                                ..op
                            },
                        );
                        replies.push(reply);
                    }
                }
                Stage::Issued(mut issued) => {
                    if op.terminal.is_none() && Instant::now() >= issued.deadline {
                        op.terminal = Some(CoreError::Deadline);
                    }
                    if op.terminal.is_some() {
                        host.actor_mut(&op.scope)?.cancel(&issued.run)?;
                        if !issued.revoked {
                            issued.revoked = true;
                            replies.push(json!({"jsonrpc":"2.0","method":crate::constants::protocol::methods::EDITOR_REVOKE_EDIT,"params":{"edit_id":id,"issued_token":issued.token,"origin_id":op.origin}}));
                        }
                    }
                    if self.disconnected {
                        let finishing = issued.finish(
                            None,
                            QuiescentEffect::OutcomeUnknown,
                            NoDispatchReason::Cancelled,
                        )?;
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Finishing(finishing),
                                ..op
                            },
                        );
                    } else {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Issued(issued),
                                ..op
                            },
                        );
                    }
                }
                Stage::Finishing(mut finishing) => {
                    if !finishing.task.is_finished() {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Finishing(finishing),
                                ..op
                            },
                        );
                        continue;
                    }
                    let result = (&mut finishing.task)
                        .now_or_never()
                        .ok_or(CoreError::CleanupFailed)?
                        .map_err(|_| CoreError::CleanupFailed)
                        .and_then(|value| value);
                    replies.extend(finishing.publish(
                        host,
                        &op.scope,
                        &op.preparation,
                        &id,
                        result,
                    )?);
                }
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
                            Ok(EditorAdmission::Authorized(grant)) => Ok(Stage::Authorized {
                                run,
                                grant,
                                witnesses: PreflightSet::default(),
                            }),
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
                Stage::Preflighting(preparing) => {
                    if op.terminal.is_none() && Instant::now() >= preparing.deadline {
                        op.terminal = Some(CoreError::Deadline);
                    }
                    if op.terminal.is_none() {
                        op.terminal = preparing.grant.revalidate(host.actor_mut(&op.scope)?).err();
                    }
                    if op.terminal.is_some() {
                        preparing.cancel.cancel();
                    }
                    if !preparing.task.is_finished() {
                        self.operations.insert(
                            id,
                            Operation {
                                stage: Stage::Preflighting(preparing),
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
                    match result {
                        Ok(preflight) => {
                            let op = Operation {
                                stage: Stage::Preflighted {
                                    run: preparing.run,
                                    grant: preparing.grant,
                                    preflight,
                                },
                                ..op
                            };
                            let reply =
                                protocol::success(&preparing.request_id, descriptor(&id, &op));
                            if reply.to_string().len() > host.frame_limit().as_usize() {
                                cleanup(host, gate, op)?;
                                replies.push(
                                    fault(CoreError::Limit).response(Some(&preparing.request_id)),
                                );
                            } else {
                                self.operations.insert(id, op);
                                replies.push(reply);
                            }
                        }
                        Err(error) => {
                            let timed_out =
                                matches!(error, CoreError::Deadline | CoreError::ApprovalExpired);
                            let terminal = if timed_out {
                                Some(CoreError::Deadline)
                            } else {
                                Some(CoreError::Cancelled)
                            };
                            cleanup(
                                host,
                                gate,
                                Operation {
                                    stage: Stage::Authorized {
                                        run: preparing.run,
                                        grant: preparing.grant,
                                        witnesses: PreflightSet::default(),
                                    },
                                    terminal,
                                    ..op
                                },
                            )?;
                            replies.push(fault(error).response(Some(&preparing.request_id)));
                        }
                    }
                }
                Stage::Preflighted {
                    run,
                    grant,
                    preflight,
                } => {
                    if op.terminal.is_none() {
                        op.terminal = grant.revalidate(host.actor_mut(&op.scope)?).err();
                    }
                    let op = Operation {
                        stage: Stage::Preflighted {
                            run,
                            grant,
                            preflight,
                        },
                        ..op
                    };
                    if op.terminal.is_some() {
                        cleanup(host, gate, op)?;
                    } else {
                        self.operations.insert(id, op);
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
                Stage::Authorized {
                    run,
                    grant,
                    witnesses,
                } => {
                    if op.terminal.is_none() {
                        op.terminal = grant.revalidate(host.actor_mut(&op.scope)?).err();
                    }
                    let op = Operation {
                        stage: Stage::Authorized {
                            run,
                            grant,
                            witnesses,
                        },
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
        Stage::Authorized { run, grant, .. } => {
            json!({"edit_id":id,"state":"authorized","scope":run.scope(),"revision":grant.revision(),"review_mode":grant.action().review_mode(),"applied":false})
        }
        Stage::Preflighted {
            run,
            grant,
            preflight,
        } => {
            json!({"edit_id":id,"state":"preflighted","scope":run.scope(),"revision":grant.revision(),"preflight":preflight.descriptor(),"applied":false})
        }
        Stage::Issued(issued) => issued.descriptor(id),
        Stage::Issuing(_) | Stage::Finishing(_) => Value::Null,
        Stage::Preflighting(_) => Value::Null,
        Stage::Preparing(_) => Value::Null,
    }
}
fn cleanup(
    host: &mut Host,
    gate: &mut ExecutionGate,
    op: Operation,
) -> Result<crate::application::RunCompletion, CoreError> {
    let actor = host.actor_mut(&op.scope)?;
    let timed_out = matches!(
        op.terminal,
        Some(CoreError::Deadline | CoreError::ApprovalExpired)
    );
    let completion = match op.stage {
        Stage::Review { run, .. } => {
            actor.cancel(&run)?;
            if timed_out {
                gate.timeout_run(actor, &run)?;
            } else {
                gate.dismiss_run(actor, &run)?;
            }
            actor.finish(&run)?
        }
        Stage::Authorized { run, grant, .. } | Stage::Preflighted { run, grant, .. } => {
            actor.cancel(&run)?;
            if timed_out {
                grant.expire_unissued(actor)?;
            } else {
                grant.cancel_unissued(actor)?;
            }
            actor.finish(&run)?
        }
        Stage::Preparing(_)
        | Stage::Preflighting(_)
        | Stage::Issuing(_)
        | Stage::Issued(_)
        | Stage::Finishing(_) => return Err(CoreError::Busy),
    };
    actor
        .edits
        .release_claim(&op.scope.session_id, &op.preparation)?;
    Ok(completion)
}

fn fault(error: CoreError) -> Fault {
    crate::edit::prepare::fault(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn claimed(
        review: &str,
    ) -> Result<
        (
            tempfile::TempDir,
            Host,
            ReadScope,
            crate::edit::prepare::ClaimWork,
        ),
        Box<dyn std::error::Error>,
    > {
        let root = tempfile::tempdir()?;
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"claim-timeout-test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result.map_err(|_|"initialize")?;
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
        let scoped = |arguments: Value| json!({"scope":{"application_id":scope.application_id,"session_id":scope.session_id},"arguments":arguments});
        let id = host.dispatch("edit/begin",scoped(json!({"origin_id":"editor_source_12345678-1234-4234-8234-123456789abc","root":root.path(),"mode":"agent","intent":{"kind":"write","path":"empty","new_bytes":0},"live":null,"config_revision":0,"policy_revision":0,"review_mode":review,"save_policy":"buffer_only"})),true).result.map_err(|_|"begin")?["preparation_id"].clone();
        let ticket = json!({"origin_id":"editor_source_12345678-1234-4234-8234-123456789abc","preparation_id":id});
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
        let preparation: PreparationId = serde_json::from_value(id)?;
        host.finish_edit(&scope, &preparation, result)
            .map_err(|_| "finish")?;
        let work =
            host.actor_mut(&scope)?
                .edits
                .claim(&scope.session_id, ticket, Instant::now())?;
        Ok((root, host, scope, work))
    }
    #[test]
    fn source_deadline_precedes_gate_deadline_and_preserves_timeout_in_both_ledgers() -> TestResult
    {
        for mode in ["auto", "async"] {
            for reason in ["expired", "cancelled"] {
                let (_root, mut host, scope, work) = claimed(mode)?;
                let preparation = work.id.clone();
                let origin = work.origin.clone();
                let prepared = work.execute(&CancellationToken::new())?;
                let actor = host.actor_mut(&scope)?;
                let run = actor.admit_editor(&scope.session_id, prepared.settings)?;
                let mut registry = ToolRegistry::default();
                let tool = ToolName::try_from("editor_edit".to_owned())?;
                registry.register_editor(tool.clone(), vec![])?;
                let mut gate = ExecutionGate::default();
                let admission = gate.admit_editor(
                    actor,
                    &run,
                    &registry,
                    &tool,
                    EditorAdmissionInput {
                        call_id: ToolCallId::new(),
                        action: prepared.action,
                        presenter: EditorPresenter::Available,
                    },
                )?;
                let stage = match admission {
                    EditorAdmission::Review(request) => Stage::Review {
                        run: run.clone(),
                        request,
                    },
                    EditorAdmission::Authorized(grant) => Stage::Authorized {
                        run: run.clone(),
                        grant,
                        witnesses: PreflightSet::default(),
                    },
                };
                assert!(matches!(actor.finish(&run), Err(CoreError::Busy)));
                assert!(matches!(
                    actor.edits.claim_status(
                        &crate::domain::SessionId::new(),
                        &preparation,
                        Instant::now()
                    ),
                    Err(CoreError::StaleOwner)
                ));
                let now = if reason == "expired" {
                    let expiry = Instant::now()
                        .checked_add(crate::constants::timeouts::APPROVAL)
                        .and_then(|time| time.checked_add(Duration::from_secs(1)))
                        .ok_or("expiry")?;
                    actor.edits.sweep(expiry);
                    expiry
                } else {
                    actor.edits.close_session(&scope.session_id);
                    Instant::now()
                };
                let terminal = actor
                    .edits
                    .claim_status(&scope.session_id, &preparation, now)
                    .err();
                assert!(if reason == "expired" {
                    matches!(terminal, Some(CoreError::Deadline))
                } else {
                    matches!(terminal, Some(CoreError::Cancelled))
                });
                let completion = cleanup(
                    &mut host,
                    &mut gate,
                    Operation {
                        scope: scope.clone(),
                        origin,
                        preparation: preparation.clone(),
                        terminal,
                        stage,
                    },
                )?;
                assert_eq!(completion.tool_results.len(), 1);
                assert_eq!(
                    completion.tool_results.first().map(|result| result.outcome),
                    Some(if reason == "expired" {
                        crate::application::ToolOutcome::Timeout
                    } else {
                        crate::application::ToolOutcome::Cancelled
                    })
                );
                assert_eq!(gate.pending_count(), 0);
                assert!(matches!(
                    host.actor_mut(&scope)?.edits.claim_status(
                        &scope.session_id,
                        &preparation,
                        now
                    ),
                    Err(CoreError::StaleOwner)
                ));
                assert!(host.actor_mut(&scope)?.drained());
            }
        }
        Ok(())
    }
    #[tokio::test]
    async fn issued_timeout_revokes_without_releasing_until_real_quiescence() -> TestResult {
        use std::os::unix::fs::PermissionsExt;
        let (_root, mut host, scope, work) = claimed("auto")?;
        let preparation = work.id.clone();
        let origin = work.origin.clone();
        let prepared = work.execute(&CancellationToken::new())?;
        let actor = host.actor_mut(&scope)?;
        let run = actor.admit_editor(&scope.session_id, prepared.settings)?;
        let mut registry = ToolRegistry::default();
        let tool = ToolName::try_from("editor_edit".to_owned())?;
        registry.register_editor(tool.clone(), vec![])?;
        let mut gate = ExecutionGate::default();
        let EditorAdmission::Authorized(grant) = gate.admit_editor(
            actor,
            &run,
            &registry,
            &tool,
            EditorAdmissionInput {
                call_id: ToolCallId::new(),
                action: prepared.action,
                presenter: EditorPresenter::Missing,
            },
        )?
        else {
            return Err("auto grant expected".into());
        };
        let artifact = actor.edits.claimed_artifact(
            &scope.session_id,
            &origin,
            &preparation,
            Instant::now(),
        )?;
        let fact: PreflightFile = serde_json::from_value(
            json!({"file":0,"base_hash":crate::edit::types::EditText::try_from(String::new())?.hash(),"document":{"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":1,"bytes":0,"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":{"kind":"absent"}}}),
        )?;
        let mut witnesses = PreflightSet::default();
        witnesses.record(&artifact, fact)?;
        let deadline = Instant::now()
            .checked_add(Duration::from_secs(3))
            .ok_or("deadline")?;
        let preflight = witnesses
            .into_work(artifact, deadline)?
            .execute(&CancellationToken::new())?;
        let directory = tempfile::tempdir()?;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))?;
        let edit = EditorEditId::new();
        let mut editors = Editors::default();
        editors.operations.insert(
            edit.clone(),
            Operation {
                scope: scope.clone(),
                origin: origin.clone(),
                preparation,
                terminal: None,
                stage: Stage::Preflighted {
                    run: run.clone(),
                    grant,
                    preflight,
                },
            },
        );
        let scoped = |arguments: Value| json!({"scope":{"application_id":scope.application_id,"session_id":scope.session_id},"arguments":arguments});
        editors.issue(&mut host,RpcId::String("issue".to_owned()),scoped(json!({"origin_id":origin,"edit_id":edit,"revision":1,"journal_directory":directory.path()})),true).map_err(|_|"issue")?;
        let issued = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                for reply in editors.tick(&mut host, &mut gate, &registry)? {
                    if reply["result"]["state"] == "issued" {
                        return Ok::<Value, CoreError>(reply["result"].clone());
                    }
                }
                tokio::task::yield_now().await;
            }
        })
        .await??;
        let op = editors.operations.get_mut(&edit).ok_or("operation")?;
        let Stage::Issued(state) = &mut op.stage else {
            return Err("issued state expected".into());
        };
        state.deadline = Instant::now();
        let notices = editors.tick(&mut host, &mut gate, &registry)?;
        assert!(
            notices
                .iter()
                .any(|notice| notice["method"] == "editor/revoke_edit")
        );
        assert_eq!(editors.reserved_workers(), 1);
        assert!(matches!(
            host.actor_mut(&scope)?.finish(&run),
            Err(CoreError::Busy)
        ));
        assert!(editors.tick(&mut host, &mut gate, &registry)?.is_empty());
        assert!(!editors.is_empty());
        editors.quiescent(&mut host,RpcId::String("settle".to_owned()),scoped(json!({"origin_id":origin,"edit_id":edit,"revision":1,"issued_token":issued["issued_token"],"effect":"not_dispatched"}))).map_err(|_|"quiescent")?;
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let replies = editors.tick(&mut host, &mut gate, &registry)?;
                if editors.is_empty() {
                    assert_eq!(replies.len(), 1);
                    assert_eq!(
                        replies
                            .first()
                            .and_then(|reply| reply.get("result"))
                            .and_then(|result| result.get("stop_reason")),
                        Some(&json!("timeout"))
                    );
                    return Ok::<(), CoreError>(());
                }
                tokio::task::yield_now().await;
            }
        })
        .await??;
        assert!(host.actor_mut(&scope)?.drained());
        Ok(())
    }
    #[tokio::test]
    async fn cancellation_after_journal_sync_waits_for_join_and_records_no_dispatch() -> TestResult
    {
        use crate::edit::journal::{
            IssuedJournal, JournalDirectory, JournalIssue, JournalResolution, RecoveredJournal,
        };
        use std::os::unix::fs::PermissionsExt;
        let (_root, mut host, scope, work) = claimed("auto")?;
        let preparation = work.id.clone();
        let origin = work.origin.clone();
        let prepared = work.execute(&CancellationToken::new())?;
        let actor = host.actor_mut(&scope)?;
        let run = actor.admit_editor(&scope.session_id, prepared.settings)?;
        let mut registry = ToolRegistry::default();
        let tool = ToolName::try_from("editor_edit".to_owned())?;
        registry.register_editor(tool.clone(), vec![])?;
        let mut gate = ExecutionGate::default();
        let EditorAdmission::Authorized(grant) = gate.admit_editor(
            actor,
            &run,
            &registry,
            &tool,
            EditorAdmissionInput {
                call_id: ToolCallId::new(),
                action: prepared.action,
                presenter: EditorPresenter::Missing,
            },
        )?
        else {
            return Err("auto grant expected".into());
        };
        let artifact = actor.edits.claimed_artifact(
            &scope.session_id,
            &origin,
            &preparation,
            Instant::now(),
        )?;
        let fact: PreflightFile = serde_json::from_value(
            json!({"file":0,"base_hash":crate::edit::types::EditText::try_from(String::new())?.hash(),"document":{"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":1,"bytes":0,"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":{"kind":"absent"}}}),
        )?;
        let mut witnesses = PreflightSet::default();
        witnesses.record(&artifact, fact)?;
        let deadline = Instant::now()
            .checked_add(Duration::from_secs(3))
            .ok_or("deadline")?;
        let preflight = witnesses
            .into_work(artifact, deadline)?
            .execute(&CancellationToken::new())?;
        let directory = tempfile::tempdir()?;
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))?;
        let journal_directory = JournalDirectory::try_from(directory.path().to_path_buf())?;
        let edit = EditorEditId::new();
        let worker_edit = edit.clone();
        let token = EditorIssueToken::new();
        let worker_token = token.clone();
        let cancel = run.cancel_token();
        let (ready, created) = mpsc::channel::<()>();
        let (release, wait) = mpsc::channel::<()>();
        let task = tokio::task::spawn_blocking(move || {
            let journal = (|| {
                let issue = JournalIssue::capture(worker_edit, grant.scope(), grant.action())?
                    .for_issuance(worker_token, preflight.digest());
                IssuedJournal::create(
                    journal_directory,
                    issue,
                    &CancellationToken::new(),
                    deadline,
                )
            })();
            let _ = ready.send(());
            let _ = wait.recv();
            issue::Recorded {
                grant,
                preflight,
                journal,
            }
        });
        let request_id = RpcId::String("held-journal".to_owned());
        let mut editors = Editors::default();
        editors.operations.insert(
            edit.clone(),
            Operation {
                scope: scope.clone(),
                origin,
                preparation,
                terminal: None,
                stage: Stage::Issuing(issue::Recording {
                    run: run.clone(),
                    token,
                    task,
                    cancel,
                    deadline,
                    request_id: request_id.clone(),
                }),
            },
        );
        created.recv_timeout(Duration::from_secs(3))?;
        assert!(matches!(
            crate::edit::journal::recover(
                JournalDirectory::try_from(directory.path().to_path_buf())?,
                edit.clone(),
                &CancellationToken::new(),
                deadline
            ),
            Err(CoreError::Busy)
        ));
        editors.cancel(&request_id);
        assert!(editors.tick(&mut host, &mut gate, &registry)?.is_empty());
        assert_eq!(editors.reserved_workers(), 1);
        assert!(matches!(
            host.actor_mut(&scope)?.finish(&run),
            Err(CoreError::Busy)
        ));
        release.send(())?;
        tokio::time::timeout(Duration::from_secs(3), async {
            let mut replies = Vec::new();
            loop {
                replies.extend(editors.tick(&mut host, &mut gate, &registry)?);
                if editors.is_empty() {
                    assert_eq!(replies.len(), 1);
                    assert_eq!(
                        replies
                            .first()
                            .and_then(|reply| reply.get("error"))
                            .and_then(|error| error.get("data"))
                            .and_then(|data| data.get("status")),
                        Some(&json!("cancelled"))
                    );
                    return Ok::<(), CoreError>(());
                }
                tokio::task::yield_now().await;
            }
        })
        .await??;
        assert!(matches!(
            crate::edit::journal::recover(
                JournalDirectory::try_from(directory.path().to_path_buf())?,
                edit,
                &CancellationToken::new(),
                deadline
            )?,
            RecoveredJournal::Resolved {
                resolution: JournalResolution::NotDispatched,
                ..
            }
        ));
        assert!(host.actor_mut(&scope)?.drained());
        Ok(())
    }
    #[tokio::test]
    async fn preflight_cancel_retains_native_grant_and_source_capacity_until_actual_join()
    -> TestResult {
        let (root, mut host, scope, work) = claimed("auto")?;
        let preparation = work.id.clone();
        let origin = work.origin.clone();
        let prepared = work.execute(&CancellationToken::new())?;
        let actor = host.actor_mut(&scope)?;
        let run = actor.admit_editor(&scope.session_id, prepared.settings)?;
        let mut registry = ToolRegistry::default();
        let tool = ToolName::try_from("editor_edit".to_owned())?;
        registry.register_editor(tool.clone(), vec![])?;
        let mut gate = ExecutionGate::default();
        let EditorAdmission::Authorized(grant) = gate.admit_editor(
            actor,
            &run,
            &registry,
            &tool,
            EditorAdmissionInput {
                call_id: ToolCallId::new(),
                action: prepared.action,
                presenter: EditorPresenter::Missing,
            },
        )?
        else {
            return Err("auto grant expected".into());
        };
        let artifact = actor.edits.claimed_artifact(
            &scope.session_id,
            &origin,
            &preparation,
            Instant::now(),
        )?;
        let fact: PreflightFile = serde_json::from_value(
            json!({"file":0,"base_hash":crate::edit::types::EditText::try_from(String::new())?.hash(),"document":{"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":1,"bytes":0,"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":{"kind":"absent"}}}),
        )?;
        let mut witnesses = PreflightSet::default();
        assert!(witnesses.record(&artifact, fact)?.ready);
        let deadline = Instant::now()
            .checked_add(Duration::from_secs(3))
            .ok_or("deadline")?;
        let work = witnesses.into_work(artifact, deadline)?;
        let cancel = CancellationToken::new();
        let worker_cancel = cancel.clone();
        let (release, wait) = mpsc::channel::<()>();
        let task = tokio::task::spawn_blocking(move || {
            wait.recv().map_err(|_| CoreError::Cancelled)?;
            work.execute(&worker_cancel)
        });
        let request_id = RpcId::String("held-preflight".to_owned());
        let mut editors = Editors::default();
        editors.operations.insert(
            EditorEditId::new(),
            Operation {
                scope: scope.clone(),
                origin,
                preparation,
                terminal: None,
                stage: Stage::Preflighting(Preflighting {
                    run: run.clone(),
                    grant,
                    task,
                    cancel,
                    request_id: request_id.clone(),
                    deadline,
                }),
            },
        );
        assert_eq!(editors.reserved_workers(), 1);
        let begin = || json!({"scope":{"application_id":scope.application_id,"session_id":scope.session_id},"arguments":{"origin_id":"editor_source_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","root":root.path(),"mode":"agent","intent":{"kind":"write","path":"empty","new_bytes":0},"live":null,"config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"buffer_only"}});
        assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
        editors.cancel(&request_id);
        assert!(editors.tick(&mut host, &mut gate, &registry)?.is_empty());
        assert_eq!(editors.reserved_workers(), 1);
        assert!(host.dispatch("edit/begin", begin(), true).result.is_err());
        assert!(matches!(
            host.actor_mut(&scope)?.finish(&run),
            Err(CoreError::Busy)
        ));
        release.send(())?;
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let replies = editors.tick(&mut host, &mut gate, &registry)?;
                if editors.is_empty() {
                    assert_eq!(replies.len(), 1);
                    assert_eq!(
                        replies
                            .first()
                            .and_then(|reply| reply.get("error"))
                            .and_then(|error| error.get("data"))
                            .and_then(|data| data.get("status")),
                        Some(&json!("cancelled"))
                    );
                    return Ok::<(), CoreError>(());
                }
                tokio::task::yield_now().await;
            }
        })
        .await??;
        assert!(host.dispatch("edit/begin", begin(), true).result.is_ok());
        assert!(host.actor_mut(&scope)?.drained());
        Ok(())
    }
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
