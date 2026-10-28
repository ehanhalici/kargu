//! A parsed patch stays actor-owned while the editor supplies named live captures.
use super::{
    Artifact, PartBuffer, Work,
    types::{Begin, Document, FileIndex, LiveDocument, Part, PreparationId},
};
use crate::{
    constants::limits,
    domain::ByteLimit,
    edit::{
        EditError,
        patch::{OperationKind, UnifiedPatch},
        types::{EditPath, HunkCount},
    },
    error::CoreError,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Instant};

pub(crate) enum PreparationResult {
    Complete(Artifact),
    Inspected(Box<Inspection>),
}
pub(super) struct Target {
    pub path: EditPath,
    pub initial: OperationKind,
    pub hunks: HunkCount,
}
pub(crate) struct Inspection {
    pub(super) input: Begin,
    pub(super) patch: UnifiedPatch,
    pub(super) targets: Vec<Target>,
    pub(super) documents: BTreeMap<EditPath, LiveDocument>,
    pub(super) parts: BTreeMap<Part, PartBuffer>,
}
impl Inspection {
    pub(super) fn new(input: Begin, patch: UnifiedPatch) -> Result<Self, CoreError> {
        let mut targets: Vec<Target> = Vec::new();
        for op in patch.operations() {
            if let Some(target) = targets.iter_mut().find(|t| &t.path == op.path()) {
                target.hunks = HunkCount::try_from(
                    target
                        .hunks
                        .get()
                        .checked_add(op.hunks().len())
                        .ok_or(EditError::Limit)?,
                )?;
            } else {
                targets.push(Target {
                    path: op.path().clone(),
                    initial: op.kind(),
                    hunks: HunkCount::try_from(op.hunks().len())?,
                });
            }
        }
        Ok(Self {
            input,
            patch,
            targets,
            documents: BTreeMap::new(),
            parts: BTreeMap::new(),
        })
    }
    pub(super) fn descriptor(&self, id: &PreparationId) -> Value {
        json!({"preparation_id":id,"inspected":true,"file_count":self.targets.len(),"hunks_total":self.patch.hunk_count(),"applied":false})
    }
    pub(super) fn targets(
        &self,
        offset: super::types::FileCursor,
        frame: ByteLimit,
    ) -> Result<Value, CoreError> {
        if offset.get() > self.targets.len() {
            return Err(EditError::InvalidEvidence.into());
        }
        let mut page = super::page::MetadataPage::new(frame)?;
        for (index, target) in self.targets.iter().enumerate().skip(offset.get()) {
            let value = json!({"path":target.path,"file":FileIndex::try_from(index)?,"initial_operation":target.initial,"hunks_total":target.hunks});
            if !page.push(value)? {
                break;
            }
        }
        page.finish(
            offset,
            super::types::FileCount::try_from(self.targets.len())?,
        )
    }
    pub(super) fn document(&mut self, input: Document) -> Result<Value, CoreError> {
        let index = self
            .targets
            .iter()
            .position(|target| target.path == input.path)
            .ok_or(EditError::InvalidEvidence)?;
        if input.document.dirty || input.document.read_only {
            return Err(EditError::Conflict.into());
        }
        if self.documents.contains_key(&input.path)
            || self
                .documents
                .values()
                .any(|doc| doc.id == input.document.id)
        {
            return Err(EditError::InvalidEvidence.into());
        }
        let size = self
            .parts
            .values()
            .try_fold(self.patch.normalized().len(), |n, part| {
                n.checked_add(part.expected.get()).ok_or(EditError::Limit)
            })?;
        if size
            .checked_add(input.document.bytes.get())
            .ok_or(EditError::Limit)?
            > limits::EDIT_BUFFER_BYTES
        {
            return Err(EditError::Limit.into());
        }
        let part = Part::DocumentAt(FileIndex::try_from(index)?);
        self.parts
            .insert(part, PartBuffer::new(input.document.bytes));
        self.documents.insert(input.path, input.document);
        Ok(json!({"part":part}))
    }
}
pub(crate) enum PrepareWork {
    Read(Work),
    Patch(PatchWork),
}
pub(crate) struct PatchWork {
    pub(crate) id: PreparationId,
    pub(super) inspection: Inspection,
    pub(super) deadline: Instant,
}
