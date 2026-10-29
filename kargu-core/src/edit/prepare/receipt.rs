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
impl ReceiptChunk {
    pub(crate) fn as_str(&self) -> &str {
        self.0.as_str()
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
    Files {
        offset: super::types::FileCursor,
    },
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
#[derive(Clone, Serialize)]
pub(crate) struct FileResult {
    file: FileIndex,
    path: crate::edit::types::EditPath,
    outcome: FileOutcome,
    base_hash: ContentHash,
    proposed_hash: ContentHash,
    written_hash: Option<ContentHash>,
    final_hash: Option<ContentHash>,
    hunks: Option<crate::edit::types::HunkCount>,
    #[serde(skip)]
    pub(super) final_text: Option<Arc<EditText>>,
    #[serde(skip)]
    pub(super) final_document: Option<LiveDocument>,
    #[serde(skip)]
    pub(super) before_document: LiveDocument,
    #[serde(skip)]
    pub(super) final_disk: DiskState,
    saved: bool,
    hook_modified: bool,
}
impl FileResult {
    pub(crate) fn outcome(&self) -> FileOutcome {
        self.outcome
    }
    pub(crate) fn final_hash(&self) -> Option<ContentHash> {
        self.final_hash
    }
    pub(crate) fn index(&self) -> FileIndex {
        self.file
    }
}
#[derive(Clone, Serialize)]
pub(crate) struct VerifiedReceipt {
    outcome: BatchOutcome,
    files: Vec<FileResult>,
    files_total: FileCount,
    files_applied: FileCount,
    hunks_total: Option<crate::edit::types::HunkCount>,
    hunks_applied: Option<crate::edit::types::HunkCount>,
}
impl VerifiedReceipt {
    pub(crate) fn has_applied(&self) -> bool {
        self.files_applied.get() > 0
    }
    pub(crate) fn files(&self) -> &[FileResult] {
        &self.files
    }
    pub(super) fn retained_bytes(&self) -> Result<usize, CoreError> {
        self.files.iter().try_fold(0usize, |n, file| {
            n.checked_add(
                file.final_text
                    .as_ref()
                    .map_or(0, |text| text.as_str().len()),
            )
            .ok_or(CoreError::Limit)
        })
    }
    pub(super) fn rebase(&mut self, path: &crate::edit::types::EditPath, version: &FileResult) {
        for file in &mut self.files {
            if &file.path == path && file.final_hash == version.final_hash {
                file.final_document = version.final_document.clone();
                file.final_disk = version.final_disk.clone();
            }
        }
    }
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
    pub(crate) fn paged_summary(&self) -> serde_json::Value {
        serde_json::json!({
            "outcome": self.outcome,
            "files": [],
            "files_total": self.files_total,
            "files_applied": self.files_applied,
            "hunks_total": self.hunks_total,
            "hunks_applied": self.hunks_applied,
            "offset": 0,
            "next_offset": 0,
            "complete": false,
        })
    }
    pub(crate) fn into_pages(self) -> ReceiptPages {
        let files = self
            .files
            .into_iter()
            .map(|mut file| {
                file.final_text = None;
                file
            })
            .collect();
        ReceiptPages {
            files,
            total: self.files_total,
        }
    }
}
/// Detached outcome metadata. Source bodies and executable rights are never retained.
pub(crate) struct ReceiptPages {
    files: Vec<FileResult>,
    total: FileCount,
}
impl ReceiptPages {
    pub(crate) fn page_files(
        &self,
        offset: super::types::FileCursor,
        frame: crate::domain::ByteLimit,
    ) -> Result<serde_json::Value, CoreError> {
        if offset.get() > self.files.len() {
            return Err(EditError::InvalidEvidence.into());
        }
        let mut page = super::page::MetadataPage::new(frame)?;
        for file in self.files.iter().skip(offset.get()) {
            let value = serde_json::to_value(file).map_err(|_| CoreError::Limit)?;
            if !page.push(value)? {
                break;
            }
        }
        page.finish(offset, self.total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paged_outcome_drops_source_body_ownership_and_keeps_metadata()
    -> Result<(), Box<dyn std::error::Error>> {
        let body = Arc::new(EditText::try_from("private source body\n".repeat(20_000))?);
        let weak = Arc::downgrade(&body);
        let hash = body.hash();
        let doc: LiveDocument = serde_json::from_value(
            serde_json::json!({"id":"editor_document_12345678-1234-4234-8234-123456789abc",
            "tick":1,"bytes":body.as_str().len(),"coding":"utf-8-unix","dirty":true,"read_only":false,"disk":{"kind":"absent"}}),
        )?;
        let receipt = VerifiedReceipt {
            outcome: BatchOutcome::AppliedFull,
            files_total: FileCount::try_from(1)?,
            files_applied: FileCount::try_from(1)?,
            hunks_total: None,
            hunks_applied: None,
            files: vec![FileResult {
                file: FileIndex::try_from(0)?,
                path: crate::edit::types::EditPath::try_from("file.txt".to_owned())?,
                outcome: FileOutcome::Applied,
                base_hash: hash,
                proposed_hash: hash,
                written_hash: Some(hash),
                final_hash: Some(hash),
                hunks: None,
                final_text: Some(body),
                final_document: Some(doc.clone()),
                before_document: doc,
                final_disk: DiskState::Absent {},
                saved: false,
                hook_modified: false,
            }],
        };
        let pages = receipt.into_pages();
        assert!(weak.upgrade().is_none());
        let page = pages.page_files(
            super::super::types::FileCursor::default(),
            crate::domain::ByteLimit::try_from(1024)?,
        )?;
        let encoded = serde_json::to_string(&page).map_err(|_| CoreError::Limit)?;
        assert!(encoded.len() < 1024);
        assert!(!encoded.contains("private source body"));
        assert_eq!(page["files"][0]["outcome"], "applied");
        Ok(())
    }
}
