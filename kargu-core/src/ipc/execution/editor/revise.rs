//! Bounded chunked and inline review-text upload for `edit/revise`.

use crate::{
    constants::limits,
    domain::ByteLimit,
    edit::{
        EditError,
        prepare::{FileIndex, TextBytes, TextOffset, receipt::ReceiptChunk},
        types::{EditText, EditorEditId, EditorRevision, EditorSourceId},
    },
    error::CoreError,
};
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum ReviseInput {
    Begin {
        file_index: FileIndex,
        new_bytes: TextBytes,
    },
    Append {
        file_index: FileIndex,
        offset: TextOffset,
        text: ReceiptChunk,
    },
    Commit {
        file_index: FileIndex,
    },
}

#[derive(Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub(super) enum ReviseRpc {
    Inline {
        origin_id: EditorSourceId,
        edit_id: EditorEditId,
        revision: EditorRevision,
        file_index: FileIndex,
        new_text: EditText,
    },
    Stream {
        origin_id: EditorSourceId,
        edit_id: EditorEditId,
        revision: EditorRevision,
        input: ReviseInput,
    },
}

impl ReviseRpc {
    pub(super) fn origin_id(&self) -> &EditorSourceId {
        match self {
            Self::Inline { origin_id, .. } | Self::Stream { origin_id, .. } => origin_id,
        }
    }
    pub(super) fn edit_id(&self) -> &EditorEditId {
        match self {
            Self::Inline { edit_id, .. } | Self::Stream { edit_id, .. } => edit_id,
        }
    }
    pub(super) fn revision(&self) -> EditorRevision {
        match self {
            Self::Inline { revision, .. } | Self::Stream { revision, .. } => *revision,
        }
    }
}

pub(super) struct RevisionUpload {
    revision: EditorRevision,
    file_index: FileIndex,
    expected: TextBytes,
    text: Zeroizing<String>,
}

impl RevisionUpload {
    pub(super) fn new(
        revision: EditorRevision,
        file_index: FileIndex,
        expected: TextBytes,
    ) -> Self {
        Self {
            revision,
            file_index,
            expected,
            text: Zeroizing::new(String::new()),
        }
    }
    pub(super) fn page_bytes(frame: ByteLimit) -> Result<usize, CoreError> {
        let budget = limits::EDIT_PAGE_BYTES.min(frame.as_usize().saturating_sub(256) / 6);
        if budget < 4 {
            return Err(CoreError::Limit);
        }
        Ok(budget)
    }
    pub(super) fn append(
        &mut self,
        edit_id: &EditorEditId,
        revision: EditorRevision,
        file_index: FileIndex,
        offset: TextOffset,
        chunk: &ReceiptChunk,
    ) -> Result<Value, CoreError> {
        if self.revision != revision || self.file_index != file_index {
            return Err(EditError::InvalidEvidence.into());
        }
        if offset.get() != self.text.len() {
            return Err(EditError::InvalidEvidence.into());
        }
        let next = self
            .text
            .len()
            .checked_add(chunk.as_str().len())
            .ok_or(EditError::Limit)?;
        if next > self.expected.get() {
            return Err(EditError::Limit.into());
        }
        self.text.push_str(chunk.as_str());
        Ok(json!({
            "edit_id": edit_id,
            "revision": revision,
            "file_index": file_index,
            "offset": next,
            "next_offset": next,
            "complete": next == self.expected.get(),
        }))
    }
    pub(super) fn take(
        self,
        revision: EditorRevision,
        file_index: FileIndex,
    ) -> Result<(FileIndex, EditText), CoreError> {
        if self.revision != revision
            || self.file_index != file_index
            || self.text.len() != self.expected.get()
        {
            return Err(EditError::InvalidEvidence.into());
        }
        let text = EditText::from_sensitive(self.text)?;
        Ok((self.file_index, text))
    }
}
