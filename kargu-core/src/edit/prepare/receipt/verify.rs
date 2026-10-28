//! Compare raw editor observations with the issued proposal and actual pinned disk.
use super::super::{Prepared, capture};
use super::*;
use crate::{
    edit::{patch::OperationKind, types::SavePolicy},
    security::file::checkpoint,
};
use tokio_util::sync::CancellationToken;

struct DiskObservation {
    state: DiskState,
    matches_final: bool,
}

fn observe_disk(
    prepared: &Prepared,
    observation: &FileObservation,
    text: &EditText,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<DiskObservation, CoreError> {
    checkpoint(cancel, deadline)?;
    prepared.root.revalidate()?;
    let (evidence, state) = capture::evidence(
        &prepared.root,
        prepared.relative.as_path(),
        cancel,
        deadline,
    )?;
    if evidence.canonical != prepared.evidence.canonical {
        return Err(EditError::Conflict.into());
    }
    let matches_final = match &observation.after {
        After::Document {
            document,
            encoded_hash,
        } if state == document.disk
            && matches!(state, DiskState::File { .. })
            && prepared.save_policy == SavePolicy::Save
            && matches!(
                observation.progress,
                Progress::Saving | Progress::SaveReturned
            ) =>
        {
            // An uploaded hash cannot assert a relationship between arbitrary logical
            // text and disk bytes. Require actual native decoding as well as raw integrity.
            let contents = capture::disk_contents(&evidence, cancel, deadline)?;
            contents.text.as_str() == text.as_str()
                && encoded_hash.is_none_or(|expected| EncodedHash(contents.raw_digest) == expected)
        }
        _ => false,
    };
    evidence.revalidate()?;
    prepared.root.revalidate()?;
    checkpoint(cancel, deadline)?;
    Ok(DiskObservation {
        state,
        matches_final,
    })
}

struct FileEvidence<'a> {
    prepared: &'a Prepared,
    before: &'a LiveDocument,
    observation: &'a FileObservation,
    written: Option<&'a EditText>,
    after: &'a EditText,
    disk: &'a DiskObservation,
    kind: OperationKind,
}
fn assess(evidence: FileEvidence<'_>, result: &mut FileResult) {
    let FileEvidence {
        prepared,
        before,
        observation,
        written,
        after,
        disk,
        kind,
    } = evidence;
    let reported_disk = match &observation.after {
        After::Document { document, .. } => &document.disk,
        After::Closed { disk, .. } => disk,
        After::Unavailable {} => return,
    };
    if reported_disk != &disk.state {
        return;
    }
    if kind == OperationKind::Delete {
        if observation.progress == Progress::Deleted
            && observation.failure.is_none()
            && matches!(&observation.after, After::Closed { .. })
            && matches!(disk.state, DiskState::Absent {})
        {
            result.outcome = FileOutcome::Applied;
            result.saved = true;
        }
        return;
    }
    let After::Document { document, .. } = &observation.after else {
        return;
    };
    let same_source = document.coding == before.coding;
    if prepared.unchanged
        && disk.state == before.disk
        && after.hash() == prepared.base_hash
        && same_source
        && observation.failure.is_none()
        && !document.dirty
    {
        result.outcome = FileOutcome::Unchanged;
        return;
    }
    let unchanged = disk.state == before.disk && after.hash() == prepared.base_hash && same_source;
    if observation.progress == Progress::NotEntered
        || (observation.progress == Progress::Replacing && observation.failure.is_some())
    {
        if unchanged {
            result.outcome = if prepared.unchanged {
                FileOutcome::Unchanged
            } else {
                FileOutcome::NotApplied
            };
        }
        return;
    }
    let Some(written) = written else {
        return;
    };
    if written.hash() != prepared.proposed_hash {
        return;
    }
    result.hook_modified = written.as_str() != after.as_str();
    result.saved = disk.matches_final;
    result.outcome = FileOutcome::Partial;
    if observation.failure.is_some() {
        return;
    }
    match (prepared.save_policy, observation.progress) {
        (SavePolicy::BufferOnly, Progress::Replaced)
            if disk.state == before.disk && !result.hook_modified =>
        {
            result.outcome = if prepared.unchanged {
                FileOutcome::Unchanged
            } else {
                FileOutcome::Applied
            };
            result.saved = false;
        }
        (SavePolicy::Save, Progress::SaveReturned) if result.saved && !document.dirty => {
            result.outcome = FileOutcome::Applied
        }
        _ => {}
    }
}

impl ReceiptWork {
    pub(crate) fn execute(
        mut self,
        cancel: &CancellationToken,
    ) -> Result<VerifiedReceipt, CoreError> {
        checkpoint(cancel, self.deadline)?;
        let count = preflight::count(&self.artifact);
        let mut results = Vec::with_capacity(count);
        let mut applied = FileCount::default();
        for number in 0..count {
            checkpoint(cancel, self.deadline)?;
            let index = FileIndex::try_from(number)?;
            let prepared = preflight::file(&self.artifact, index)?;
            let before = self.preflight.document(index)?;
            let FileUpload {
                observation,
                written,
                after,
            } = self
                .collection
                .files
                .remove(&index)
                .ok_or(EditError::InvalidEvidence)?;
            let written = written
                .map(|part| EditText::from_sensitive(part.text))
                .transpose()?;
            let after = EditText::from_sensitive(after.text)?;
            let kind = match &*self.artifact {
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
            let mut result = FileResult {
                file: index,
                path: prepared.relative.clone(),
                outcome: FileOutcome::OutcomeUnknown,
                base_hash: prepared.base_hash,
                proposed_hash: prepared.proposed_hash,
                written_hash: written.as_ref().map(EditText::hash),
                final_hash: match observation.after {
                    After::Document { .. } => Some(after.hash()),
                    _ => None,
                },
                saved: false,
                hook_modified: false,
            };
            match observe_disk(prepared, &observation, &after, cancel, self.deadline) {
                Ok(disk) => assess(
                    FileEvidence {
                        prepared,
                        before,
                        observation: &observation,
                        written: written.as_ref(),
                        after: &after,
                        disk: &disk,
                        kind,
                    },
                    &mut result,
                ),
                Err(error @ (CoreError::Deadline | CoreError::Cancelled)) => return Err(error),
                Err(_) => {}
            }
            if matches!(result.outcome, FileOutcome::Applied) {
                applied = FileCount::try_from(
                    applied
                        .get()
                        .checked_add(1)
                        .ok_or(CoreError::ArithmeticOverflow)?,
                )?;
            }
            results.push(result);
        }
        checkpoint(cancel, self.deadline)?;
        let outcome = if results
            .iter()
            .any(|file| file.outcome == FileOutcome::OutcomeUnknown)
        {
            BatchOutcome::OutcomeUnknown
        } else if results
            .iter()
            .all(|file| matches!(file.outcome, FileOutcome::Applied | FileOutcome::Unchanged))
        {
            BatchOutcome::AppliedFull
        } else if results
            .iter()
            .all(|file| file.outcome == FileOutcome::NotApplied)
        {
            BatchOutcome::NotApplied
        } else {
            BatchOutcome::AppliedPartial
        };
        Ok(VerifiedReceipt {
            outcome,
            files: results,
            files_total: FileCount::try_from(count)?,
            files_applied: applied,
        })
    }
}
