//! Journal IO owns its actual worker join; issued ownership waits for real quiescence.
use crate::{
    application::{RunHandle, host::Host},
    constants::timeouts,
    edit::{
        journal::{
            IssuedJournal, JournalCommit, JournalDirectory, JournalIssue, JournalResolution,
        },
        prepare::{
            Artifact, ReadyPreflight,
            receipt::{ReceiptCollection, VerifiedReceipt},
        },
        types::{EditorEditId, EditorIssueToken, NoDispatchReason, QuiescentEffect},
    },
    error::CoreError,
    ipc::protocol::{self, RpcId},
    security::file::checkpoint,
    security::{AuthorizedEditorEdit, IssuedEditorEdit},
};
use serde_json::{Value, json};
use std::{sync::Arc, time::Instant};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

pub(super) struct Start {
    pub run: RunHandle,
    pub grant: AuthorizedEditorEdit,
    pub preflight: ReadyPreflight,
    pub id: EditorEditId,
    pub directory: JournalDirectory,
    pub artifact: Arc<Artifact>,
    pub request_id: RpcId,
}
pub(super) struct Recorded {
    pub artifact: Arc<Artifact>,
    pub grant: AuthorizedEditorEdit,
    pub preflight: ReadyPreflight,
    pub journal: Result<IssuedJournal, CoreError>,
}
pub(super) struct Recording {
    pub run: RunHandle,
    pub token: EditorIssueToken,
    pub task: JoinHandle<Recorded>,
    pub cancel: CancellationToken,
    pub deadline: Instant,
    pub request_id: RpcId,
}
pub(super) struct Issued {
    pub artifact: Arc<Artifact>,
    pub run: RunHandle,
    pub token: EditorIssueToken,
    pub effect: IssuedEditorEdit,
    pub journal: IssuedJournal,
    pub preflight: ReadyPreflight,
    pub deadline: Instant,
    pub revoked: bool,
    pub receipts: ReceiptCollection,
}
pub(super) enum Completion {
    Unissued {
        grant: AuthorizedEditorEdit,
        request_id: RpcId,
        error: CoreError,
    },
    Quiescent {
        effect: IssuedEditorEdit,
        request_id: Option<RpcId>,
        observed: QuiescentEffect,
        reason: NoDispatchReason,
    },
    Receipt {
        effect: IssuedEditorEdit,
        request_id: Option<RpcId>,
        receipt: Box<VerifiedReceipt>,
    },
}
pub(super) struct Finishing {
    pub run: RunHandle,
    pub task: JoinHandle<Result<JournalCommit, CoreError>>,
    pub completion: Completion,
}
fn deadline() -> Result<Instant, CoreError> {
    Instant::now()
        .checked_add(timeouts::EDIT_JOURNAL)
        .ok_or(CoreError::ArithmeticOverflow)
}
impl Recording {
    pub(super) fn start(input: Start) -> Result<Self, CoreError> {
        let deadline = deadline()?;
        let token = EditorIssueToken::new();
        let worker_token = token.clone();
        let cancel = input.run.cancel_token();
        let worker_cancel = cancel.clone();
        let task = tokio::task::spawn_blocking(move || {
            let journal = (|| {
                input.grant.check_worker()?;
                checkpoint(&worker_cancel, deadline)?;
                input
                    .preflight
                    .revalidate(&input.artifact, &worker_cancel, deadline)?;
                let issue =
                    JournalIssue::capture(input.id, input.grant.scope(), input.grant.action())?
                        .for_issuance(worker_token, input.preflight.digest());
                IssuedJournal::create(input.directory, issue, &worker_cancel, deadline)
            })();
            Recorded {
                artifact: input.artifact,
                grant: input.grant,
                preflight: input.preflight,
                journal,
            }
        });
        Ok(Self {
            run: input.run,
            token,
            task,
            cancel,
            deadline,
            request_id: input.request_id,
        })
    }
}
impl Issued {
    pub(super) fn descriptor(&self, id: &EditorEditId) -> Value {
        json!({"edit_id":id,"state":"issued","issued_token":self.token,"revision":self.effect.revision(),"preflight_digest":self.preflight.digest(),"applied":null})
    }
    pub(super) fn finish(
        self,
        request_id: Option<RpcId>,
        observed: QuiescentEffect,
        reason: NoDispatchReason,
    ) -> Result<Finishing, CoreError> {
        let resolution = match observed {
            QuiescentEffect::NotDispatched => JournalResolution::NotDispatched,
            QuiescentEffect::OutcomeUnknown => JournalResolution::OutcomeUnknown,
        };
        Finishing::start(
            self.run,
            self.journal,
            Completion::Quiescent {
                effect: self.effect,
                request_id,
                observed,
                reason,
            },
            resolution,
        )
    }
}
impl Finishing {
    pub(super) fn finish_receipt(
        run: RunHandle,
        journal: IssuedJournal,
        effect: IssuedEditorEdit,
        request_id: Option<RpcId>,
        receipt: Box<VerifiedReceipt>,
    ) -> Result<Self, CoreError> {
        let digest = receipt.digest()?;
        let resolution = JournalResolution::Receipt { digest };
        Finishing::start(
            run,
            journal,
            Completion::Receipt {
                effect,
                request_id,
                receipt,
            },
            resolution,
        )
    }
    pub(super) fn start(
        run: RunHandle,
        journal: IssuedJournal,
        completion: Completion,
        resolution: JournalResolution,
    ) -> Result<Self, CoreError> {
        let deadline = deadline()?;
        // Teardown cannot cancel a terminal journal append. Its real join releases the reservation.
        let task = tokio::task::spawn_blocking(move || {
            journal.resolve(resolution, &CancellationToken::new(), deadline)
        });
        Ok(Self {
            run,
            task,
            completion,
        })
    }
    pub(super) fn publish(
        self,
        host: &mut Host,
        scope: &crate::application::host::ReadScope,
        preparation: &crate::edit::prepare::PreparationId,
        id: &EditorEditId,
        result: Result<JournalCommit, CoreError>,
    ) -> Result<Vec<Value>, CoreError> {
        let live_owner = host.owns_read_scope(scope);
        let actor = host.actor_mut(scope)?;
        let expected = match &self.completion {
            Completion::Unissued { .. } => JournalResolution::NotDispatched,
            Completion::Quiescent {
                observed: QuiescentEffect::NotDispatched,
                ..
            } => JournalResolution::NotDispatched,
            Completion::Quiescent {
                observed: QuiescentEffect::OutcomeUnknown,
                ..
            } => JournalResolution::OutcomeUnknown,
            Completion::Receipt { receipt, .. } => JournalResolution::Receipt {
                digest: receipt.digest()?,
            },
        };
        let durable = result
            .as_ref()
            .is_ok_and(|commit| commit.id() == id && commit.resolution() == &expected);
        let mut replies = Vec::new();
        match self.completion {
            Completion::Unissued {
                grant,
                request_id,
                error,
            } => {
                if matches!(error, CoreError::Deadline | CoreError::ApprovalExpired) {
                    grant.expire_unissued(actor)?;
                } else {
                    grant.cancel_unissued(actor)?;
                }
                replies.push(super::fault(error).response(Some(&request_id)));
            }
            Completion::Quiescent {
                effect,
                request_id,
                observed,
                reason,
            } => {
                let observed = if durable {
                    observed
                } else {
                    QuiescentEffect::OutcomeUnknown
                };
                effect.complete_quiescent(actor, observed, reason)?;
                if let Some(request_id) = request_id {
                    replies.push(if durable {protocol::success(&request_id,json!({"edit_id":id,"state":"quiescent","effect":observed,"stop_reason":reason,"journal_committed":true}))}else{crate::ipc::protocol::Fault {code:crate::constants::protocol::error_codes::OUTCOME_UNKNOWN,status:"outcome_unknown",message:"Editor journal settlement failed; do not replay this operation"}.response(Some(&request_id))});
                }
            }
            Completion::Receipt {
                effect,
                request_id,
                receipt,
            } => {
                let outcome = if durable {
                    receipt.outcome()
                } else {
                    crate::application::ToolOutcome::OutcomeUnknown
                };
                let rollback_available = if durable && live_owner && receipt.has_applied() {
                    actor
                        .edits
                        .record_applied(&scope.session_id, id, preparation, &receipt)
                        .unwrap_or(false)
                } else {
                    false
                };
                effect.complete(actor, outcome)?;
                if let Some(request_id) = request_id {
                    replies.push(if durable {
                        protocol::success(
                            &request_id,
                            json!({
                                "edit_id": id,
                                "state": "quiescent",
                                "receipt": receipt,
                                "rollback_available":rollback_available,
                                "journal_committed": true
                            }),
                        )
                    } else {
                        crate::ipc::protocol::Fault {
                            code: crate::constants::protocol::error_codes::OUTCOME_UNKNOWN,
                            status: "outcome_unknown",
                            message: "Editor journal settlement failed; do not replay this operation",
                        }
                        .response(Some(&request_id))
                    });
                }
            }
        }
        actor.finish(&self.run)?;
        actor.edits.release_claim(&scope.session_id, preparation)?;
        Ok(replies)
    }
}
