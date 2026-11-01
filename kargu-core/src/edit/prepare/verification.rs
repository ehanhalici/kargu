//! Receipt-bound evidence for one native conversation diagnostic read.
#[cfg(test)]
mod tests;
use super::{
    history::{ChangedFileRecord, HistoryRevision},
    types::FileIndex,
};
use crate::{
    domain::SessionId,
    edit::types::{ContentHash, EditorEditId},
    error::CoreError,
    sensors::diagnostics::{DiagnosticSnapshot, DocumentStamp},
};
use std::{collections::VecDeque, path::Path};

/// Single-use publication capture. Neither caller JSON nor a path can mint it.
pub(crate) struct VerificationTicket {
    session: SessionId,
    edit: EditorEditId,
    revision: HistoryRevision,
    file: FileIndex,
    hash: ContentHash,
    document: DocumentStamp,
}
fn matches_document(row: &ChangedFileRecord, document: &DocumentStamp) -> bool {
    row.path == document.path
        && row.document.as_ref().is_some_and(|saved| {
            String::from(saved.id.clone()) == document.document_id.as_str()
                && saved.tick.get() == document.tick.get()
        })
}
pub(super) fn capture(
    changes: &VecDeque<ChangedFileRecord>,
    session: &SessionId,
    root: &Path,
    document: &DocumentStamp,
) -> Option<VerificationTicket> {
    let row = changes.iter().find(|row| {
        &row.session == session
            && row.service_id.is_none()
            && row.root == root
            && row.verification_pending
            && matches_document(row, document)
    })?;
    Some(VerificationTicket {
        session: session.clone(),
        edit: row.edit_id.clone(),
        revision: row.revision,
        file: row.file,
        hash: row.final_hash?,
        document: document.clone(),
    })
}
pub(super) fn settle(
    changes: &mut VecDeque<ChangedFileRecord>,
    revision: &mut HistoryRevision,
    session: &SessionId,
    ticket: VerificationTicket,
    snapshot: &DiagnosticSnapshot,
) -> Result<bool, CoreError> {
    if &ticket.session != session || snapshot.document() != &ticket.document || !snapshot.is_clean()
        // Compatibility labels may have been guessed by an older frontend.
        // Read them normally, but only native grading can settle nonempty evidence.
        || snapshot.diagnostics().iter().any(|finding| !finding.has_native_severity())
    {
        return Ok(false);
    }
    let Some(row) = changes.iter_mut().find(|row| {
        &row.session == session
            && row.service_id.is_none()
            && row.verification_pending
            && row.edit_id == ticket.edit
            && row.revision == ticket.revision
            && row.file == ticket.file
            && row.final_hash == Some(ticket.hash)
            && matches_document(row, &ticket.document)
    }) else {
        return Ok(false);
    };
    revision.advance()?;
    row.verification_pending = false;
    Ok(true)
}
