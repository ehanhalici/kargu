//! Revision-bound, read-only projections of native undo and change history.
//!
//! Rows carry no source bodies or execution grants. A multi-page reader must
//! retain the returned revision; a concurrent edit invalidates its continuation.

use super::{
    AppliedSnapshot,
    page::MetadataPage,
    receipt::FileOutcome,
    types::{DiskState, FileCount, FileCursor, FileIndex, LiveDocument},
};
use crate::{
    domain::{ByteLimit, EditServiceId, SessionId},
    edit::{
        EditError,
        types::{ContentHash, EditPath, EditorEditId, HunkCount},
    },
    error::CoreError,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::VecDeque, path::PathBuf};

/// Distinct pending or still-claimed changes, bounded before editor admission.
#[derive(Default)]
pub(super) struct ChangeReservations(std::collections::HashSet<ChangeKey>);
#[derive(Eq, Hash, PartialEq)]
struct ChangeKey {
    session: SessionId,
    service: Option<EditServiceId>,
    path: PathBuf,
}
impl ChangeReservations {
    fn reserve(
        &mut self,
        session: &SessionId,
        service: &Option<EditServiceId>,
        path: &std::path::Path,
    ) -> Result<(), CoreError> {
        let key = ChangeKey {
            session: session.clone(),
            service: service.clone(),
            path: path.to_path_buf(),
        };
        if !self.0.contains(&key) && self.0.len() >= crate::constants::limits::EDIT_FILES {
            return Err(CoreError::Limit);
        }
        self.0.insert(key);
        Ok(())
    }
    pub(super) fn change(&mut self, record: &ChangedFileRecord) -> Result<(), CoreError> {
        self.reserve(&record.session, &record.service_id, &record.full_path)
    }
    pub(super) fn artifact(
        &mut self,
        session: &SessionId,
        service: &Option<EditServiceId>,
        artifact: &super::Artifact,
    ) -> Result<(), CoreError> {
        match artifact {
            super::Artifact::File(file) => self.reserve(session, service, &file.path),
            super::Artifact::Batch(batch) => {
                for file in &batch.files {
                    self.reserve(session, service, &file.proposal.path)?;
                }
                Ok(())
            }
        }
    }
}

#[derive(Clone, Copy, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct HistoryRevision(u64);

impl HistoryRevision {
    pub(super) fn advance(&mut self) -> Result<(), CoreError> {
        self.0 = self.0.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?;
        Ok(())
    }
}

/// Publication identity captured by the single writer with the receipt.
#[derive(Default)]
pub(crate) struct AppliedPublication {
    pub(crate) rollback_available: bool,
    pub(crate) edit_revision: Option<HistoryRevision>,
}

/// No retained baseline is different from an originally absent file.
#[derive(Clone, Copy)]
pub(super) enum ChangeBaseline {
    Known(Option<ContentHash>),
    Unavailable,
}
impl ChangeBaseline {
    pub(super) fn matches(self, hash: Option<ContentHash>) -> bool {
        matches!(self, Self::Known(original) if original == hash)
    }
}

#[derive(Clone)]
pub(super) struct ChangedFileRecord {
    pub(super) session: SessionId,
    pub(super) service_id: Option<EditServiceId>,
    pub(super) edit_id: EditorEditId,
    pub(super) revision: HistoryRevision,
    pub(super) file: FileIndex,
    pub(super) root: PathBuf,
    pub(super) full_path: PathBuf,
    pub(super) path: EditPath,
    pub(super) outcome: FileOutcome,
    pub(super) final_hash: Option<ContentHash>,
    // Original content identity survives undo body eviction.
    pub(super) baseline: ChangeBaseline,
    pub(super) document: Option<LiveDocument>,
    pub(super) disk: DiskState,
    pub(super) hunks: Option<HunkCount>,
    pub(super) saved: bool,
    pub(super) hook_modified: bool,
    pub(super) verification_pending: bool,
}

/// Bounded conversation evidence; retained rows are not a complete run audit.
#[derive(Serialize)]
pub(crate) struct ChangeSummary {
    revision: HistoryRevision,
    pending_files: FileCount,
    retained_files: FileCount,
}
impl ChangeSummary {
    pub(super) fn capture(
        session: &SessionId,
        revision: HistoryRevision,
        changes: &VecDeque<ChangedFileRecord>,
    ) -> Result<Self, CoreError> {
        let owned: Vec<_> = changes
            .iter()
            .filter(|row| &row.session == session && row.service_id.is_none())
            .collect();
        Ok(Self {
            revision,
            pending_files: FileCount::try_from(
                owned.iter().filter(|row| row.verification_pending).count(),
            )?,
            retained_files: FileCount::try_from(owned.len())?,
        })
    }
}

pub(super) fn publish_change(
    changes: &mut VecDeque<ChangedFileRecord>,
    record: ChangedFileRecord,
) -> Result<(), CoreError> {
    while changes.len() >= crate::constants::limits::EDIT_FILES {
        // A pending verification is debt, independent of undo snapshot eviction.
        let consumed = changes
            .iter()
            .position(|row| !row.verification_pending)
            .ok_or(CoreError::CleanupFailed)?;
        changes.remove(consumed);
    }
    changes.push_back(record);
    Ok(())
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum HistoryQuery {
    List {
        offset: FileCursor,
        revision: Option<HistoryRevision>,
        service_id: Option<EditServiceId>,
    },
    Files {
        edit_id: EditorEditId,
        offset: FileCursor,
        revision: HistoryRevision,
        service_id: Option<EditServiceId>,
    },
    Changes {
        offset: FileCursor,
        revision: Option<HistoryRevision>,
        service_id: Option<EditServiceId>,
        pending_only: Option<bool>,
    },
    Consume {
        edit_id: EditorEditId,
        edit_revision: HistoryRevision,
        file: FileIndex,
        final_hash: Option<ContentHash>,
        service_id: Option<EditServiceId>,
    },
    ResetChanges {
        service_id: Option<EditServiceId>,
    },
    CloseService {
        service_id: EditServiceId,
    },
}

pub(super) fn execute(
    snapshots: &mut VecDeque<AppliedSnapshot>,
    changes: &mut VecDeque<ChangedFileRecord>,
    session: &SessionId,
    current: &mut HistoryRevision,
    input: HistoryQuery,
    frame: ByteLimit,
) -> Result<Value, CoreError> {
    match input {
        HistoryQuery::Consume {
            edit_id,
            edit_revision,
            file,
            final_hash,
            service_id,
        } => {
            let mut consumed = false;
            if let Some(record) = changes.iter_mut().find(|record| {
                &record.session == session
                    && record.service_id == service_id
                    && record.edit_id == edit_id
                    && record.revision == edit_revision
                    && record.file == file
                    && record.final_hash == final_hash
            }) && record.verification_pending
            {
                record.verification_pending = false;
                consumed = true;
                current.advance()?;
            }
            return Ok(json!({
                "consumed": consumed,
                "revision": *current,
            }));
        }
        HistoryQuery::ResetChanges { service_id } => {
            let before = changes.len();
            changes
                .retain(|record| !(&record.session == session && record.service_id == service_id));
            if changes.len() != before {
                current.advance()?;
            }
            return Ok(json!({
                "reset": true,
                "revision": *current,
            }));
        }
        HistoryQuery::CloseService { .. } => {
            return Err(CoreError::Unavailable);
        }
        _ => {}
    }

    let (offset, revision) = match &input {
        HistoryQuery::List {
            offset, revision, ..
        }
        | HistoryQuery::Changes {
            offset, revision, ..
        } => (*offset, *revision),
        HistoryQuery::Files {
            offset, revision, ..
        } => (*offset, Some(*revision)),
        _ => return Err(EditError::InvalidEvidence.into()),
    };
    if revision.is_some_and(|revision| revision != *current)
        || (offset.get() != 0 && revision.is_none())
    {
        return Err(CoreError::StaleOwner);
    }
    // Reserve the additional revision member, including its largest u64 spelling.
    let mut page = MetadataPage::new(ByteLimit::try_from(frame.as_usize().saturating_sub(32))?)?;
    let total = match input {
        HistoryQuery::List { service_id, .. } => {
            let owned: Vec<_> = snapshots
                .iter()
                .rev()
                .filter(|s| &s.session == session && s.service_id == service_id)
                .collect();
            if offset.get() > owned.len() {
                return Err(EditError::InvalidEvidence.into());
            }
            for snapshot in owned.iter().skip(offset.get()) {
                if !page.push(
                    json!({"edit_id": snapshot.edit_id, "files_total": snapshot.remaining.len()}),
                )? {
                    break;
                }
            }
            FileCount::try_from(owned.len())?
        }
        HistoryQuery::Files {
            edit_id,
            service_id,
            ..
        } => {
            let snapshot = snapshots
                .iter()
                .find(|s| {
                    &s.session == session && s.edit_id == edit_id && s.service_id == service_id
                })
                .ok_or(CoreError::Unavailable)?;
            if offset.get() > snapshot.remaining.len() {
                return Err(EditError::InvalidEvidence.into());
            }
            for index in snapshot.remaining.iter().skip(offset.get()) {
                let file = super::preflight::file(&snapshot.artifact, *index)?;
                let receipt = snapshot
                    .receipt
                    .files()
                    .get(index.get())
                    .ok_or(EditError::InvalidEvidence)?;
                if !page.push(json!({
                    "edit_id": snapshot.edit_id,
                    "file": index,
                    "root": file.root.path(),
                    "path": file.relative,
                    "final_hash": receipt.final_hash(),
                    "document": receipt.final_document,
                    "disk": receipt.final_disk,
                }))? {
                    break;
                }
            }
            FileCount::try_from(snapshot.remaining.len())?
        }
        HistoryQuery::Changes {
            service_id,
            pending_only,
            ..
        } => {
            let owned: Vec<_> = changes
                .iter()
                .rev()
                .filter(|record| {
                    &record.session == session
                        && record.service_id == service_id
                        && (!pending_only.unwrap_or(false) || record.verification_pending)
                })
                .collect();
            if offset.get() > owned.len() {
                return Err(EditError::InvalidEvidence.into());
            }
            for record in owned.iter().skip(offset.get()) {
                if !page.push(json!({
                    "edit_id": record.edit_id,
                    "edit_revision": record.revision,
                    "file": record.file,
                    "root": record.root,
                    "path": record.path,
                    "outcome": record.outcome,
                    "final_hash": record.final_hash,
                    "document": record.document,
                    "disk": record.disk,
                    "hunks": record.hunks,
                    "saved": record.saved,
                    "hook_modified": record.hook_modified,
                    "verification_pending": record.verification_pending,
                }))? {
                    break;
                }
            }
            FileCount::try_from(owned.len())?
        }
        _ => return Err(EditError::InvalidEvidence.into()),
    };
    let mut result = page.finish(offset, total)?;
    result
        .as_object_mut()
        .ok_or(EditError::InvalidEvidence)?
        .insert("revision".into(), json!(*current));
    Ok(result)
}
