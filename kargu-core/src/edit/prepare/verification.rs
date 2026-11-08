//! Receipt-bound evidence for one native conversation diagnostic read.
#[cfg(test)]
mod tests;
use super::{
    Prepared,
    history::{ChangedFileRecord, HistoryRevision},
    types::{FileIndex, LiveDocument},
};
#[cfg(test)]
use crate::edit::types::EditPath;
use crate::{
    application::agent::HealingVerdict,
    constants::limits,
    domain::{EditServiceId, SessionId},
    edit::types::{ContentHash, EditorEditId},
    error::CoreError,
    sensors::diagnostics::{
        Diagnostic, DiagnosticDelta, DiagnosticSnapshot, DocumentStamp, Freshness,
        HealingSignature, Severity,
    },
};
use std::{collections::VecDeque, path::Path};

fn has_native_severities(snapshot: &DiagnosticSnapshot) -> bool {
    snapshot
        .diagnostics()
        .iter()
        .all(Diagnostic::has_native_severity)
}

fn has_errors(snapshot: &DiagnosticSnapshot) -> bool {
    snapshot
        .diagnostics()
        .iter()
        .any(|d| d.severity() == Severity::Error)
}

/// Pre-edit diagnostic baseline bound to the exact preflight document and hash.
#[derive(Clone, Default)]
pub(crate) enum DiagnosticBaseline {
    #[default]
    Unavailable,
    Captured {
        base_hash: ContentHash,
        snapshot: Box<DiagnosticSnapshot>,
    },
}

impl DiagnosticBaseline {
    pub(super) fn capture(
        prepared: &Prepared,
        document: &LiveDocument,
        candidate: Option<&DiagnosticSnapshot>,
    ) -> Self {
        let Some(snapshot) = candidate.filter(|_| prepared.evidence.existed()) else {
            return Self::Unavailable;
        };
        if snapshot.freshness() != Freshness::Fresh
            || !has_native_severities(snapshot)
            || snapshot.document().path != prepared.relative
            || snapshot.document().document_id().as_str() != String::from(document.id.clone())
            || snapshot.document().tick().get() != document.tick.get()
        {
            return Self::Unavailable;
        }
        Self::Captured {
            base_hash: prepared.base_hash,
            snapshot: Box::new(snapshot.clone()),
        }
    }
    pub(super) fn base_hash(&self) -> Option<ContentHash> {
        match self {
            Self::Unavailable => None,
            Self::Captured { base_hash, .. } => Some(*base_hash),
        }
    }
    pub(super) fn compare(&self, post: &DiagnosticSnapshot) -> Option<DiagnosticDelta> {
        let Self::Captured { snapshot, .. } = self else {
            return None;
        };
        if post.freshness() != Freshness::Fresh
            || !has_native_severities(post)
            || post.document().tick().get() <= snapshot.document().tick().get()
        {
            return None;
        }
        post.compare_errors(snapshot)
    }
    pub(super) fn healing_signature(&self, post: &DiagnosticSnapshot) -> Option<HealingSignature> {
        let Self::Captured { snapshot, .. } = self else {
            return None;
        };
        if post.freshness() != Freshness::Fresh
            || !has_native_severities(post)
            || post.document().tick().get() <= snapshot.document().tick().get()
        {
            return None;
        }
        post.new_error_signature(snapshot)
    }
}

fn render_healing_suffix(verdict: Option<HealingVerdict>) -> String {
    match verdict {
        Some(HealingVerdict::Admitted { round }) => format!(
            "\nSELF-HEALING (round {} of {}): fix the new error(s) in this file under the current run budget.",
            round.get(),
            limits::AGENT_HEALING_ROUNDS
        ),
        Some(HealingVerdict::RepeatedErrors) => {
            "\nSELF-HEALING STOPPED: identical diagnostic error(s) repeated; do not loop on the same edit.".to_owned()
        }
        Some(HealingVerdict::BudgetExhausted) => format!(
            "\nSELF-HEALING BUDGET SPENT ({0} of {0} rounds used): do not claim this edit is verified.",
            limits::AGENT_HEALING_ROUNDS
        ),
        None => String::new(),
    }
}

/// Rendered baseline comparison note for a verified diagnostic read.
pub(crate) struct BaselineNote(String);
impl BaselineNote {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

/// Exact verification target state for a pending publication record.
#[derive(Clone)]
pub(crate) enum VerificationTarget {
    LiveDocument {
        document: LiveDocument,
        final_hash: ContentHash,
    },
    ClosedFile,
    DeletedFile,
}

/// One scheduled pending verification item bound to exact publication identity.
#[cfg(test)]
#[derive(Clone)]
pub(crate) struct ScheduledVerification {
    session: SessionId,
    service_id: Option<EditServiceId>,
    edit: EditorEditId,
    revision: HistoryRevision,
    file: FileIndex,
    path: EditPath,
    target: VerificationTarget,
}
#[cfg(test)]
impl ScheduledVerification {
    pub(super) fn session(&self) -> &SessionId {
        &self.session
    }
    pub(super) fn service_id(&self) -> Option<&EditServiceId> {
        self.service_id.as_ref()
    }
    pub(super) fn edit_id(&self) -> &EditorEditId {
        &self.edit
    }
    pub(super) fn revision(&self) -> HistoryRevision {
        self.revision
    }
    pub(super) fn file(&self) -> FileIndex {
        self.file
    }
    pub(super) fn path(&self) -> &EditPath {
        &self.path
    }
    pub(super) fn target(&self) -> &VerificationTarget {
        &self.target
    }
}

fn classify_target(row: &ChangedFileRecord) -> VerificationTarget {
    let Some(final_hash) = row.final_hash else {
        return VerificationTarget::DeletedFile;
    };
    match &row.document {
        Some(document) => VerificationTarget::LiveDocument {
            document: document.clone(),
            final_hash,
        },
        None => VerificationTarget::ClosedFile,
    }
}

#[cfg(test)]
pub(super) fn schedule_pending(
    changes: &VecDeque<ChangedFileRecord>,
    session: &SessionId,
    service_id: Option<&EditServiceId>,
) -> Vec<ScheduledVerification> {
    changes
        .iter()
        .filter(|row| {
            &row.session == session
                && row.service_id.as_ref() == service_id
                && row.verification_pending
        })
        .map(|row| ScheduledVerification {
            session: row.session.clone(),
            service_id: row.service_id.clone(),
            edit: row.edit_id.clone(),
            revision: row.revision,
            file: row.file,
            path: row.path.clone(),
            target: classify_target(row),
        })
        .collect()
}

/// Single-use publication capture. Neither caller JSON nor a path can mint it.
pub(crate) struct VerificationTicket {
    session: SessionId,
    service_id: Option<EditServiceId>,
    edit: EditorEditId,
    revision: HistoryRevision,
    file: FileIndex,
    hash: ContentHash,
    document: DocumentStamp,
    baseline: DiagnosticBaseline,
}
impl VerificationTicket {
    pub(crate) fn healing_signature(
        &self,
        snapshot: &DiagnosticSnapshot,
    ) -> Option<HealingSignature> {
        if snapshot.document() != &self.document || snapshot.freshness() != Freshness::Fresh {
            return None;
        }
        self.baseline.healing_signature(snapshot)
    }
    pub(crate) fn baseline_note(
        &self,
        snapshot: &DiagnosticSnapshot,
        verdict: Option<HealingVerdict>,
    ) -> Option<BaselineNote> {
        if snapshot.document() != &self.document || snapshot.freshness() != Freshness::Fresh {
            return None;
        }
        let note = match self.baseline.compare(snapshot) {
            Some(delta) => format!(
                "\nBaseline comparison: {} new error(s), {} pre-existing error(s), {} resolved error(s).{}",
                delta.new.get(),
                delta.pre_existing.get(),
                delta.resolved.get(),
                if delta.new.get() > 0 {
                    render_healing_suffix(verdict)
                } else {
                    String::new()
                }
            ),
            None if has_errors(snapshot) => {
                "\nBaseline comparison unavailable: observed errors cannot be classified as new or pre-existing. Do not claim a regression-free edit.".to_owned()
            }
            None => {
                "\nBaseline comparison unavailable: pre-edit baseline is unavailable or producer/document identity changed.".to_owned()
            }
        };
        Some(BaselineNote(note))
    }
}
fn matches_document(row: &ChangedFileRecord, document: &DocumentStamp) -> bool {
    let VerificationTarget::LiveDocument {
        document: saved,
        final_hash,
    } = classify_target(row)
    else {
        return false;
    };
    row.final_hash == Some(final_hash)
        && row.path == document.path
        && String::from(saved.id) == document.document_id().as_str()
        && saved.tick.get() == document.tick().get()
}
fn settles_debt(
    ticket: &VerificationTicket,
    row: &ChangedFileRecord,
    snapshot: &DiagnosticSnapshot,
) -> bool {
    if snapshot.document() != &ticket.document || !has_native_severities(snapshot) {
        return false;
    }
    if snapshot.is_clean() {
        return true;
    }
    row.baseline.diagnostics().base_hash() == ticket.baseline.base_hash()
        && row
            .baseline
            .diagnostics()
            .compare(snapshot)
            .is_some_and(|delta| delta.new.get() == 0)
}
fn capture_for_service(
    changes: &VecDeque<ChangedFileRecord>,
    owner: (&SessionId, Option<&EditServiceId>),
    target: (&Path, &DocumentStamp),
) -> Option<VerificationTicket> {
    let (session, service_id) = owner;
    let (root, document) = target;
    let row = changes.iter().find(|row| {
        &row.session == session
            && row.service_id.as_ref() == service_id
            && row.root == root
            && row.verification_pending
            && matches_document(row, document)
    })?;
    Some(VerificationTicket {
        session: session.clone(),
        service_id: row.service_id.clone(),
        edit: row.edit_id.clone(),
        revision: row.revision,
        file: row.file,
        hash: row.final_hash?,
        document: document.clone(),
        baseline: row.baseline.diagnostics().clone(),
    })
}
pub(super) fn capture(
    changes: &VecDeque<ChangedFileRecord>,
    session: &SessionId,
    root: &Path,
    document: &DocumentStamp,
) -> Option<VerificationTicket> {
    capture_for_service(changes, (session, None), (root, document))
}
pub(super) fn settle(
    changes: &mut VecDeque<ChangedFileRecord>,
    revision: &mut HistoryRevision,
    session: &SessionId,
    ticket: VerificationTicket,
    snapshot: &DiagnosticSnapshot,
) -> Result<bool, CoreError> {
    if &ticket.session != session {
        return Ok(false);
    }
    let Some(row) = changes.iter_mut().find(|row| {
        &row.session == session
            && row.service_id == ticket.service_id
            && row.verification_pending
            && row.edit_id == ticket.edit
            && row.revision == ticket.revision
            && row.file == ticket.file
            && row.final_hash == Some(ticket.hash)
            && matches_document(row, &ticket.document)
    }) else {
        return Ok(false);
    };
    if !settles_debt(&ticket, row, snapshot) {
        return Ok(false);
    }
    revision.advance()?;
    row.verification_pending = false;
    Ok(true)
}
