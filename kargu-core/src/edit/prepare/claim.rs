//! Consuming preparation claim; source text is shared, never copied or re-uploaded.
use super::{
    Artifact, Prepared,
    types::{OriginId, PreparationId},
};
use crate::{
    application::{Mode, PreparedEditorSettings, RunSettings},
    constants::timeouts,
    domain::ToolCallLimit,
    edit::{
        EditError,
        intent::{EditorAction, EditorActionInput, EditorFileInput},
        patch::OperationKind,
        types::{CaptureDigest, EditorRevision},
    },
    error::CoreError,
    security::file::checkpoint,
};
use std::{sync::Arc, time::Instant};
use tokio_util::sync::CancellationToken;

pub(crate) struct ClaimWork {
    pub(crate) id: PreparationId,
    pub(crate) origin: OriginId,
    pub(super) artifact: Arc<Artifact>,
    pub(super) deadline: Instant,
}
pub(crate) struct ClaimedAction {
    pub(crate) action: EditorAction,
    pub(crate) settings: PreparedEditorSettings,
}
impl ClaimWork {
    pub(crate) fn execute(self, cancel: &CancellationToken) -> Result<ClaimedAction, CoreError> {
        checkpoint(cancel, self.deadline)?;
        let entries: Vec<(&Prepared, OperationKind)> = match self.artifact.as_ref() {
            Artifact::File(file) => vec![(
                file,
                if file.evidence.existed() {
                    OperationKind::Update
                } else {
                    OperationKind::Add
                },
            )],
            Artifact::Batch(batch) => batch
                .files
                .iter()
                .map(|file| (&file.proposal, file.kind))
                .collect(),
        };
        let (first, _) = entries.first().ok_or(EditError::InvalidEvidence)?;
        let root = first.root.clone();
        let config = first.config_revision;
        let policy = first.policy_revision;
        let review = first.review_mode;
        let save = first.save_policy;
        root.revalidate()?;
        let mut files = Vec::with_capacity(entries.len());
        for (file, kind) in entries {
            checkpoint(cancel, self.deadline)?;
            if !root.same_capture(&file.root)
                || file.config_revision != config
                || file.policy_revision != policy
                || file.review_mode != review
                || file.save_policy != save
            {
                return Err(EditError::InvalidEvidence.into());
            }
            file.evidence.revalidate()?;
            let evidence = serde_json::to_vec(&file.descriptor(&self.id))
                .map_err(|_| CoreError::InvalidToolOutput)?;
            let capture = CaptureDigest::capture(&evidence);
            let path = file.relative.clone();
            files.push(match kind {
                OperationKind::Add => EditorFileInput::Add {
                    path,
                    proposed: file.proposed.clone(),
                    capture,
                },
                OperationKind::Update => EditorFileInput::Update {
                    path,
                    base: file.base.clone(),
                    proposed: file.proposed.clone(),
                    capture,
                },
                OperationKind::Delete => EditorFileInput::Delete {
                    path,
                    base: file.base.clone(),
                    capture,
                },
            });
        }
        let action = EditorAction::try_from(EditorActionInput {
            source: self.origin,
            revision: EditorRevision::try_from(1)?,
            workspace: root.clone(),
            config_revision: config,
            policy_revision: policy,
            review_mode: review,
            save_policy: save,
            files,
        })?;
        let settings = RunSettings::new(
            Mode::Agent,
            root,
            ToolCallLimit::default(),
            timeouts::APPROVAL,
            config,
            policy,
        )?
        .prepare_editor()?;
        checkpoint(cancel, self.deadline)?;
        Ok(ClaimedAction { action, settings })
    }
}
