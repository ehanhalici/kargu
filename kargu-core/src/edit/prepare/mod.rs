//! Session/source-owned bounded proposal staging. This port cannot grant editor writes.
mod artifact;
mod claim;
pub(crate) use claim::{ClaimWork, ClaimedAction};
mod capture;
mod git;
mod inspection;
mod page;
pub(crate) use artifact::Artifact;
use artifact::Prepared;
pub(crate) use git::{GitPreparation, PatchPrepared, RunningPatch};
pub(crate) use inspection::{PatchWork, PreparationResult, PrepareWork};
mod preflight;
mod service;
pub(crate) use preflight::{PreflightFile, PreflightSet, ReadyPreflight};
mod types;
use crate::{
    edit::{EditError, types::EditText},
    error::CoreError,
};
pub(crate) use service::EditPreparations;
use std::{collections::BTreeMap, time::Instant};
pub(crate) use types::PreparationId;
use types::{Begin, Part};
use zeroize::Zeroizing;

/// Consuming, owned worker input. It cannot publish into the application actor.
pub(crate) struct Work {
    pub(crate) id: PreparationId,
    input: Begin,
    parts: BTreeMap<Part, PartBuffer>,
    deadline: Instant,
}
impl Work {
    fn take(&mut self, part: Part) -> Result<EditText, CoreError> {
        let buffer = self.parts.remove(&part).ok_or(EditError::InvalidEvidence)?;
        if !buffer.complete() {
            return Err(EditError::InvalidEvidence.into());
        }
        EditText::from_sensitive(buffer.text).map_err(CoreError::from)
    }
}
struct PartBuffer {
    expected: types::TextBytes,
    text: Zeroizing<String>,
}
impl PartBuffer {
    fn new(expected: types::TextBytes) -> Self {
        Self {
            expected,
            text: Zeroizing::new(String::new()),
        }
    }
    fn complete(&self) -> bool {
        self.text.len() == self.expected.get()
    }
    fn append(&mut self, offset: types::TextOffset, text: &str) -> Result<(), CoreError> {
        if offset.get() != self.text.len() {
            return Err(EditError::InvalidEvidence.into());
        }
        let end = self
            .text
            .len()
            .checked_add(text.len())
            .ok_or(EditError::Limit)?;
        if end > self.expected.get() {
            return Err(EditError::Limit.into());
        }
        self.text.push_str(text);
        Ok(())
    }
}
pub(crate) fn fault(error: CoreError) -> crate::ipc::protocol::Fault {
    use crate::constants::protocol::error_codes as codes;
    let (code, status, message) = match error {
        CoreError::Edit(EditError::Limit) | CoreError::Limit => (
            codes::RESOURCE_LIMIT,
            "resource_limit",
            "Edit preparation resource limit exceeded",
        ),
        CoreError::Edit(EditError::MissingMatch) => (
            codes::WORKSPACE_CHANGED,
            "missing_match",
            "Edit context does not match",
        ),
        CoreError::Edit(EditError::AmbiguousMatch) => (
            codes::WORKSPACE_CHANGED,
            "ambiguous_match",
            "Edit context is not unique",
        ),
        CoreError::Edit(EditError::MissingTarget) => (
            codes::WORKSPACE_CHANGED,
            "missing_target",
            "Edit target does not exist",
        ),
        CoreError::Edit(EditError::PatchFailed) => (
            codes::WORKSPACE_CHANGED,
            "patch_failed",
            "Git refused isolated patch preparation",
        ),
        CoreError::Edit(EditError::Conflict) | CoreError::WorkspaceChanged => (
            codes::WORKSPACE_CHANGED,
            "conflict",
            "Edit source changed or cannot be safely captured",
        ),
        CoreError::Rejected => (
            codes::REJECTED,
            "rejected",
            "Edit preparation is not permitted",
        ),
        CoreError::Unavailable => (
            codes::METHOD_NOT_FOUND,
            "unavailable",
            "Native edit preparation dependency is unavailable",
        ),
        CoreError::Cancelled => (codes::CANCELLED, "cancelled", "Edit preparation cancelled"),
        CoreError::Deadline | CoreError::ApprovalExpired => {
            (codes::TIMEOUT, "timeout", "Edit preparation expired")
        }
        CoreError::StaleOwner | CoreError::AlreadyCompleted => (
            codes::STALE_OWNER,
            "stale_owner",
            "Edit preparation owner is stale or foreign",
        ),
        CoreError::Io(_) => (codes::IO, "io_error", "Edit source capture failed"),
        CoreError::InvalidValue {
            field: "FileEncoding",
        } => (
            codes::INVALID_PARAMS,
            "unsupported_encoding",
            "Edit source requires editor decoding",
        ),
        _ => (
            codes::INVALID_PARAMS,
            "invalid_params",
            "Invalid edit preparation arguments",
        ),
    };
    crate::ipc::protocol::Fault {
        code,
        status,
        message,
    }
}
