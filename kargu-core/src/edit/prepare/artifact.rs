//! Immutable file and batch proposal views; no write authority.
use super::{
    capture,
    types::{self, DiskState, LiveDocument, PreparationId, ReviewMode, SavePolicy},
};
use crate::{
    constants::limits,
    domain::{ConfigRevision, PolicyRevision},
    edit::{
        EditError,
        patch::OperationKind,
        types::{ContentHash, EditPath, EditText, HunkCount},
    },
    error::CoreError,
    security::Workspace,
};
use serde_json::{Value, json};
use std::{path::PathBuf, sync::Arc};
// Identical text is not enough for a no-op: saving an absent target creates a
// file, while an existing live-only buffer may already satisfy buffer_only.
pub(super) fn unchanged(
    evidence: &capture::Evidence,
    live: Option<&LiveDocument>,
    kind: OperationKind,
    save: SavePolicy,
    base: ContentHash,
    proposed: ContentHash,
) -> bool {
    match kind {
        OperationKind::Delete => !evidence.existed(),
        OperationKind::Add | OperationKind::Update => {
            base == proposed
                && (evidence.existed() || (live.is_some() && save == SavePolicy::BufferOnly))
        }
    }
}
/// Private immutable proposal and held evidence; serializing a descriptor cannot
/// manufacture an execution grant or rewrite any of its contents.
#[derive(Clone)]
pub(crate) struct Prepared {
    pub(super) root: Workspace,
    pub(super) path: PathBuf,
    pub(super) relative: EditPath,
    pub(super) evidence: Arc<capture::Evidence>,
    pub(super) disk: DiskState,
    pub(super) base: Arc<EditText>,
    pub(super) proposed: Arc<EditText>,
    pub(super) base_hash: ContentHash,
    pub(super) proposed_hash: ContentHash,
    pub(super) unchanged: bool,
    pub(super) live: Option<LiveDocument>,
    pub(super) config_revision: ConfigRevision,
    pub(super) policy_revision: PolicyRevision,
    pub(super) review_mode: ReviewMode,
    pub(super) save_policy: SavePolicy,
    pub(super) restore_dirty: Option<bool>,
    pub(super) restore_coding: Option<super::types::Coding>,
}
impl Prepared {
    pub(super) fn descriptor(&self, id: &PreparationId) -> Value {
        json!({"preparation_id":id,"root":self.root.path(),"path":self.path,"requested_path":self.relative,
        "existed":self.evidence.existed(),"base_hash":self.base_hash,"proposed_hash":self.proposed_hash,
        "base_bytes":self.base.as_str().len(),"proposed_bytes":self.proposed.as_str().len(),"unchanged":self.unchanged,
        "document":self.live,"disk":self.disk,"config_revision":self.config_revision,"policy_revision":self.policy_revision,
        "review_mode":self.review_mode,"save_policy":self.save_policy,"restore_dirty":self.restore_dirty,"restore_coding":self.restore_coding,"applied":false})
    }
    pub(super) fn page(
        &self,
        part: types::PreparedPart,
        offset: types::TextOffset,
        frame: crate::domain::ByteLimit,
    ) -> Result<Value, CoreError> {
        let text = match part {
            types::PreparedPart::Base => &self.base,
            types::PreparedPart::Proposed => &self.proposed,
        }
        .as_str();
        let start = offset.get();
        if !text.is_char_boundary(start) {
            return Err(EditError::InvalidEvidence.into());
        }
        let limit = limits::EDIT_PAGE_BYTES.min(frame.as_usize().saturating_sub(256) / 6);
        if limit < 4 {
            return Err(CoreError::Limit);
        }
        let mut end = start
            .checked_add(limit)
            .ok_or(EditError::Limit)?
            .min(text.len());
        while !text.is_char_boundary(end) {
            end = end.checked_sub(1).ok_or(EditError::InvalidEvidence)?;
        }
        let slice = text.get(start..end).ok_or(EditError::InvalidEvidence)?;
        Ok(
            json!({"text":slice,"offset":types::TextOffset::try_from(start)?,"next_offset":types::TextOffset::try_from(end)?,"complete":end==text.len()}),
        )
    }
    pub(super) fn revise(&mut self, new_text: Arc<EditText>) -> Result<(), CoreError> {
        let proposed = new_text;
        let proposed_hash = proposed.hash();
        let kind = if self.evidence.existed() {
            OperationKind::Update
        } else {
            OperationKind::Add
        };
        let is_unchanged = unchanged(
            &self.evidence,
            self.live.as_ref(),
            kind,
            self.save_policy,
            self.base_hash,
            proposed_hash,
        );
        self.proposed = proposed;
        self.proposed_hash = proposed_hash;
        self.unchanged = is_unchanged;
        Ok(())
    }
}

#[derive(Clone)]
pub(super) struct BatchFile {
    pub(super) proposal: Prepared,
    pub(super) kind: OperationKind,
    pub(super) hunks: Option<HunkCount>,
}
#[derive(Clone)]
pub(crate) struct Batch {
    pub(super) files: Vec<BatchFile>,
    pub(super) hunks: Option<HunkCount>,
}
#[derive(Clone)]
pub(crate) enum Artifact {
    File(Box<Prepared>),
    Batch(Box<Batch>),
}
impl Artifact {
    pub(crate) fn retained_bytes(&self) -> Result<types::RetainedBytes, CoreError> {
        let mut count = types::RetainedBytes::default();
        match self {
            Self::File(file) => {
                count.include(&file.base)?;
                count.include(&file.proposed)?;
            }
            Self::Batch(batch) => {
                for file in &batch.files {
                    count.include(&file.proposal.base)?;
                    count.include(&file.proposal.proposed)?;
                }
            }
        }
        Ok(count)
    }
    pub(super) fn descriptor(&self, id: &PreparationId) -> Value {
        match self {
            Self::File(p) => p.descriptor(id),
            Self::Batch(b) => {
                json!({"preparation_id":id,"file_count":b.files.len(),"hunks_total":b.hunks,"batch":true,"applied":false})
            }
        }
    }
    pub(super) fn page(
        &self,
        file: Option<types::FileIndex>,
        part: types::PreparedPart,
        offset: types::TextOffset,
        frame: crate::domain::ByteLimit,
    ) -> Result<Value, CoreError> {
        match self {
            Self::File(p) if file.is_none() => p.page(part, offset, frame),
            Self::Batch(b) => b
                .files
                .get(file.ok_or(EditError::InvalidEvidence)?.get())
                .ok_or(EditError::InvalidEvidence)?
                .proposal
                .page(part, offset, frame),
            _ => Err(EditError::InvalidEvidence.into()),
        }
    }
    pub(super) fn files(
        &self,
        id: &PreparationId,
        offset: super::types::FileCursor,
        frame: crate::domain::ByteLimit,
    ) -> Result<Value, CoreError> {
        let Self::Batch(b) = self else {
            return Err(EditError::InvalidEvidence.into());
        };
        if offset.get() > b.files.len() {
            return Err(EditError::InvalidEvidence.into());
        }
        let mut page = super::page::MetadataPage::new(frame)?;
        for (index, file) in b.files.iter().enumerate().skip(offset.get()) {
            let mut value = file.proposal.descriptor(id);
            let object = value.as_object_mut().ok_or(EditError::InvalidEvidence)?;
            object.insert("operation".into(), json!(file.kind));
            object.insert("hunks_total".into(), json!(file.hunks));
            object.insert("file".into(), json!(types::FileIndex::try_from(index)?));
            if !page.push(value)? {
                break;
            }
        }
        page.finish(offset, types::FileCount::try_from(b.files.len())?)
    }
    pub(crate) fn revise(
        &mut self,
        file_index: types::FileIndex,
        new_text: Arc<EditText>,
    ) -> Result<(), CoreError> {
        match self {
            Self::File(prepared) => {
                if file_index.get() != 0 {
                    return Err(EditError::InvalidEvidence.into());
                }
                prepared.revise(new_text)
            }
            Self::Batch(batch) => {
                let file = batch
                    .files
                    .get_mut(file_index.get())
                    .ok_or(EditError::InvalidEvidence)?;
                if file.kind == OperationKind::Delete {
                    return Err(EditError::InvalidEvidence.into());
                }
                let proposed = new_text;
                let proposed_hash = proposed.hash();
                let is_unchanged = unchanged(
                    &file.proposal.evidence,
                    file.proposal.live.as_ref(),
                    file.kind,
                    file.proposal.save_policy,
                    file.proposal.base_hash,
                    proposed_hash,
                );
                file.proposal.proposed = proposed;
                file.proposal.proposed_hash = proposed_hash;
                file.proposal.unchanged = is_unchanged;
                file.hunks = None;
                batch.hunks = None;
                Ok(())
            }
        }
    }
}
