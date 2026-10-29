//! Worker-only inversion of committed, version-bound editor effects.
use super::{
    Artifact,
    artifact::{Batch, BatchFile, Prepared, unchanged},
    capture, preflight,
    receipt::{FileOutcome, VerifiedReceipt},
    types::{FileIndex, OriginId, PreparationId, ReviewMode, SavePolicy},
};
use crate::{
    application::Mode,
    domain::{ConfigRevision, PolicyRevision, SessionId},
    edit::{
        EditError,
        patch::OperationKind,
        types::{EditPath, EditText, EditorEditId},
    },
    error::CoreError,
    security::file::checkpoint,
};
use serde::Deserialize;
use std::{collections::BTreeSet, path::PathBuf, sync::Arc, time::Instant};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub(crate) struct AppliedSnapshot {
    pub session: SessionId,
    pub edit_id: EditorEditId,
    pub artifact: Arc<Artifact>,
    pub receipt: Arc<VerifiedReceipt>,
    pub remaining: BTreeSet<FileIndex>,
}
impl AppliedSnapshot {
    pub(super) fn retained_bytes(&self) -> Result<usize, CoreError> {
        self.artifact
            .retained_bytes()?
            .get()
            .checked_add(self.receipt.retained_bytes()?)
            .ok_or(CoreError::Limit)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RollbackInput {
    pub origin_id: OriginId,
    pub target_edit_id: Option<EditorEditId>,
    pub target_file: Option<EditPath>,
    pub root: Option<PathBuf>,
    pub mode: Mode,
    pub review_mode: ReviewMode,
    pub save_policy: SavePolicy,
    pub config_revision: ConfigRevision,
    pub policy_revision: PolicyRevision,
}
pub(crate) struct RollbackWork {
    pub id: PreparationId,
    pub(super) snapshot: AppliedSnapshot,
    pub(super) files: Vec<FileIndex>,
    pub(super) input: RollbackInput,
}
impl RollbackWork {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<super::PreparationResult, CoreError> {
        let mut files = Vec::with_capacity(self.files.len());
        for index in &self.files {
            checkpoint(cancel, deadline)?;
            let prepared = preflight::file(&self.snapshot.artifact, *index)?;
            let result = self
                .snapshot
                .receipt
                .files()
                .get(index.get())
                .ok_or(EditError::InvalidEvidence)?;
            if result.outcome() != FileOutcome::Applied {
                return Err(EditError::Conflict.into());
            }
            prepared.root.revalidate()?;
            let (evidence, disk) = capture::evidence(
                &prepared.root,
                prepared.relative.as_path(),
                cancel,
                deadline,
            )?;
            if disk != result.final_disk || evidence.canonical != prepared.evidence.canonical {
                return Err(EditError::Conflict.into());
            }
            let original_kind = match &*self.snapshot.artifact {
                Artifact::File(_) if prepared.evidence.existed() => OperationKind::Update,
                Artifact::File(_) => OperationKind::Add,
                Artifact::Batch(batch) => {
                    batch
                        .files
                        .get(index.get())
                        .ok_or(EditError::InvalidEvidence)?
                        .kind
                }
            };
            let base = result
                .final_text
                .clone()
                .unwrap_or_else(|| Arc::new(EditText::default()));
            if let Some(hash) = result.final_hash()
                && base.hash() != hash
            {
                return Err(EditError::InvalidEvidence.into());
            }
            let (kind, proposed) = match original_kind {
                OperationKind::Add if prepared.save_policy == SavePolicy::BufferOnly => {
                    (OperationKind::Update, prepared.base.clone())
                }
                OperationKind::Add => (OperationKind::Delete, Arc::new(EditText::default())),
                OperationKind::Update => (OperationKind::Update, prepared.base.clone()),
                OperationKind::Delete => (OperationKind::Add, prepared.base.clone()),
            };
            let base_hash = base.hash();
            let proposed_hash = proposed.hash();
            let live = result.final_document.clone();
            let is_unchanged = unchanged(
                &evidence,
                live.as_ref(),
                kind,
                self.input.save_policy,
                base_hash,
                proposed_hash,
            );
            files.push(BatchFile {
                kind,
                hunks: None,
                proposal: Prepared {
                    root: prepared.root.clone(),
                    path: prepared.path.clone(),
                    relative: prepared.relative.clone(),
                    evidence: std::sync::Arc::new(evidence),
                    disk,
                    base,
                    proposed,
                    base_hash,
                    proposed_hash,
                    unchanged: is_unchanged,
                    live,
                    config_revision: self.input.config_revision,
                    policy_revision: self.input.policy_revision,
                    review_mode: self.input.review_mode,
                    save_policy: self.input.save_policy,
                    restore_dirty: if self.input.save_policy == SavePolicy::Save
                        || prepared.save_policy == SavePolicy::BufferOnly
                    {
                        Some(false)
                    } else {
                        None
                    },
                    restore_coding: Some(result.before_document.coding.clone()),
                },
            });
        }
        let artifact = Artifact::Batch(Box::new(Batch { files, hunks: None }));
        artifact.retained_bytes()?;
        checkpoint(cancel, deadline)?;
        Ok(super::PreparationResult::Complete(artifact))
    }
}
