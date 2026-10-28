//! Bounded raw editor observations. Only native validation derives an outcome.
mod verify;
use super::{
    Artifact, PartBuffer, ReadyPreflight, preflight,
    types::{
        DiskState, DocumentId, DocumentTick, FileCount, FileIndex, LiveDocument, TextBytes,
        TextOffset,
    },
};
use crate::{
    constants::limits,
    edit::{
        EditError,
        types::{CaptureDigest, ContentHash, EditText},
    },
    error::CoreError,
};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, sync::Arc, time::Instant};
use zeroize::Zeroizing;

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ReceiptPart {
    Written,
    After,
}
#[derive(Clone, Copy, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Progress {
    NotEntered,
    Replacing,
    Replaced,
    Saving,
    SaveReturned,
    Deleting,
    Deleted,
}
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AdapterFailure {
    Error,
    Quit,
}

#[derive(Clone, Copy, Eq, PartialEq, Deserialize, Serialize)]
#[serde(transparent)]
pub(crate) struct EncodedHash(CaptureDigest);

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum After {
    Document {
        document: LiveDocument,
        encoded_hash: Option<EncodedHash>,
    },
    Closed {
        document_id: DocumentId,
        disk: DiskState,
    },
    Unavailable {},
}
impl After {
    fn bytes(&self) -> TextBytes {
        match self {
            Self::Document { document, .. } => document.bytes,
            _ => TextBytes::default(),
        }
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct FileObservation {
    pub(crate) file: FileIndex,
    pub(crate) progress: Progress,
    pub(crate) failure: Option<AdapterFailure>,
    pub(crate) write_tick: Option<DocumentTick>,
    pub(crate) written_bytes: Option<TextBytes>,
    pub(crate) after: After,
}
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(crate) struct ReceiptChunk(Zeroizing<String>);
impl TryFrom<String> for ReceiptChunk {
    type Error = EditError;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        if text.len() > limits::EDIT_PAGE_BYTES {
            return Err(EditError::Limit);
        }
        Ok(Self(Zeroizing::new(text)))
    }
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum ReceiptInput {
    File {
        observation: FileObservation,
    },
    Append {
        file: FileIndex,
        part: ReceiptPart,
        offset: TextOffset,
        text: ReceiptChunk,
    },
    Commit {},
}
struct FileUpload {
    observation: FileObservation,
    written: Option<PartBuffer>,
    after: PartBuffer,
}
#[derive(Default)]
struct ReceiptBytes(usize);
impl ReceiptBytes {
    fn include(&self, written: TextBytes, after: TextBytes) -> Result<Self, CoreError> {
        let count = self
            .0
            .checked_add(written.get())
            .and_then(|n| n.checked_add(after.get()))
            .ok_or(EditError::Limit)?;
        if count > limits::EDIT_RECEIPT_BYTES {
            return Err(EditError::Limit.into());
        }
        Ok(Self(count))
    }
}
#[derive(Default)]
pub(crate) struct ReceiptCollection {
    files: BTreeMap<FileIndex, FileUpload>,
    bytes: ReceiptBytes,
}
impl ReceiptCollection {
    pub(crate) fn record(
        &mut self,
        artifact: &Artifact,
        preflight: &ReadyPreflight,
        observation: FileObservation,
    ) -> Result<serde_json::Value, CoreError> {
        preflight::file(artifact, observation.file)?;
        let before = preflight.document(observation.file)?;
        if self.files.contains_key(&observation.file) {
            return Err(CoreError::AlreadyCompleted);
        }
        match &observation.after {
            After::Document { document, .. }
                if document.id != before.id || document.tick < before.tick =>
            {
                return Err(EditError::Conflict.into());
            }
            After::Closed { document_id, .. } if document_id != &before.id => {
                return Err(EditError::Conflict.into());
            }
            _ => {}
        }
        let needs_written = matches!(
            observation.progress,
            Progress::Replaced | Progress::Saving | Progress::SaveReturned
        );
        if needs_written != observation.written_bytes.is_some()
            || needs_written != observation.write_tick.is_some()
        {
            return Err(EditError::InvalidEvidence.into());
        }
        if let Some(tick) = observation.write_tick {
            if tick < before.tick {
                return Err(EditError::Conflict.into());
            }
            if let After::Document { document, .. } = &observation.after
                && document.tick < tick
            {
                return Err(EditError::Conflict.into());
            }
        }
        // A deletion report cannot substitute for an approved update or add.
        let deleting = matches!(observation.progress, Progress::Deleting | Progress::Deleted);
        let is_delete = match artifact {
            Artifact::File(_) => false,
            Artifact::Batch(batch) => batch
                .files
                .get(observation.file.get())
                .is_some_and(|file| file.kind == crate::edit::patch::OperationKind::Delete),
        };
        if deleting && !is_delete {
            return Err(EditError::InvalidEvidence.into());
        }
        let bytes = self.bytes.include(
            observation.written_bytes.unwrap_or_default(),
            observation.after.bytes(),
        )?;
        let file = observation.file;
        let upload = FileUpload {
            written: observation.written_bytes.map(PartBuffer::new),
            after: PartBuffer::new(observation.after.bytes()),
            observation,
        };
        self.files.insert(file, upload);
        self.bytes = bytes;
        Ok(
            serde_json::json!({"file":file,"recorded":true,"files_received":self.files.len(),"files_total":preflight::count(artifact)}),
        )
    }
    pub(crate) fn append(
        &mut self,
        file: FileIndex,
        part: ReceiptPart,
        offset: TextOffset,
        text: ReceiptChunk,
    ) -> Result<serde_json::Value, CoreError> {
        let upload = self
            .files
            .get_mut(&file)
            .ok_or(EditError::InvalidEvidence)?;
        let buffer = match part {
            ReceiptPart::Written => upload.written.as_mut().ok_or(EditError::InvalidEvidence)?,
            ReceiptPart::After => &mut upload.after,
        };
        buffer.append(offset, text.0.as_str())?;
        Ok(
            serde_json::json!({"file":file,"part":part,"next_offset":buffer.text.len(),"complete":buffer.complete()}),
        )
    }
    pub(crate) fn complete(&self, artifact: &Artifact) -> bool {
        self.files.len() == preflight::count(artifact)
            && self.files.values().all(|file| {
                file.after.complete() && file.written.as_ref().is_none_or(PartBuffer::complete)
            })
    }
    pub(crate) fn into_work(
        self,
        artifact: Arc<Artifact>,
        preflight: ReadyPreflight,
        deadline: Instant,
    ) -> Result<ReceiptWork, CoreError> {
        if !self.complete(&artifact) {
            return Err(EditError::InvalidEvidence.into());
        }
        Ok(ReceiptWork {
            collection: self,
            artifact,
            preflight,
            deadline,
        })
    }
}
pub(crate) struct ReceiptWork {
    collection: ReceiptCollection,
    artifact: Arc<Artifact>,
    preflight: ReadyPreflight,
    deadline: Instant,
}

#[derive(Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FileOutcome {
    Applied,
    Unchanged,
    Partial,
    NotApplied,
    OutcomeUnknown,
}
#[derive(Clone, Copy, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BatchOutcome {
    AppliedFull,
    AppliedPartial,
    NotApplied,
    OutcomeUnknown,
}
#[derive(Serialize)]
pub(crate) struct FileResult {
    file: FileIndex,
    path: crate::edit::types::EditPath,
    outcome: FileOutcome,
    base_hash: ContentHash,
    proposed_hash: ContentHash,
    written_hash: Option<ContentHash>,
    final_hash: Option<ContentHash>,
    saved: bool,
    hook_modified: bool,
}
#[derive(Serialize)]
pub(crate) struct VerifiedReceipt {
    outcome: BatchOutcome,
    files: Vec<FileResult>,
    files_total: FileCount,
    files_applied: FileCount,
}
impl VerifiedReceipt {
    pub(crate) fn digest(&self) -> Result<CaptureDigest, CoreError> {
        Ok(CaptureDigest::capture(
            &serde_json::to_vec(self).map_err(|_| CoreError::InvalidToolOutput)?,
        ))
    }
    pub(crate) fn outcome(&self) -> crate::application::ToolOutcome {
        match self.outcome {
            BatchOutcome::AppliedFull => crate::application::ToolOutcome::Ok,
            BatchOutcome::AppliedPartial | BatchOutcome::NotApplied => {
                crate::application::ToolOutcome::Failed
            }
            BatchOutcome::OutcomeUnknown => crate::application::ToolOutcome::OutcomeUnknown,
        }
    }
}
