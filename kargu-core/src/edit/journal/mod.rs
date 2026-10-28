//! Bounded append-only editor issuance evidence. This module never grants writes.
//!
//! All filesystem operations belong on a bounded blocking worker. Issue is synced
//! before its consuming journal state is returned; resolution is synced afterward.
//! Recovery projects evidence only and has no execution or replay API.
mod metadata;
mod storage;
use crate::{
    application::RunScope,
    constants::limits,
    edit::{
        EditError,
        intent::EditorAction,
        types::{CaptureDigest, EditorEditId, EditorRevision},
    },
    error::CoreError,
    security::file::checkpoint,
};
use metadata::StoredAction;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{path::PathBuf, time::Instant};
use tokio_util::sync::CancellationToken;

/// Explicit existing private journal directory, separate from the editor workspace.
/// Parsing performs no IO; the worker pins and checks the actual directory.
#[derive(Clone)]
pub struct JournalDirectory(PathBuf);
impl TryFrom<PathBuf> for JournalDirectory {
    type Error = CoreError;
    fn try_from(path: PathBuf) -> Result<Self, CoreError> {
        let text = path.to_str().ok_or(EditError::InvalidPath)?;
        if !path.is_absolute()
            || text.len() > limits::SEARCH_PATH_BYTES
            || text.chars().any(char::is_control)
            || path
                .components()
                .any(|part| matches!(part, std::path::Component::ParentDir))
        {
            return Err(EditError::InvalidPath.into());
        }
        Ok(Self(path))
    }
}
/// Frozen editor intent metadata. It contains no source bodies or execution authority.
/// It is journal data, not authorization or live filesystem-preflight evidence.
#[derive(Serialize, Deserialize)]
#[serde(try_from = "IssueInput")]
pub struct JournalIssue {
    id: EditorEditId,
    scope: RunScope,
    revision: EditorRevision,
    workspace: PathBuf,
    action: StoredAction,
}
impl JournalIssue {
    /// Freeze supplied native scope and immutable intent metadata on the worker.
    pub fn capture(
        id: EditorEditId,
        scope: &RunScope,
        action: &EditorAction,
    ) -> Result<Self, CoreError> {
        Self::try_from(IssueInput {
            id,
            scope: scope.clone(),
            revision: action.revision(),
            workspace: action.workspace().path().to_path_buf(),
            action: serde_json::from_value(action.metadata().clone())
                .map_err(|_| CoreError::InvalidToolOutput)?,
        })
    }
    /// Recorded native operation identity; never a capability.
    pub fn id(&self) -> &EditorEditId {
        &self.id
    }
    /// Recorded actual application/session/run/generation and settings revisions.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Recorded immutable review revision.
    pub fn revision(&self) -> EditorRevision {
        self.revision
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IssueInput {
    id: EditorEditId,
    scope: RunScope,
    revision: EditorRevision,
    workspace: PathBuf,
    action: StoredAction,
}
impl TryFrom<IssueInput> for JournalIssue {
    type Error = CoreError;
    fn try_from(input: IssueInput) -> Result<Self, CoreError> {
        JournalDirectory::try_from(input.workspace.clone())?;
        if input.workspace != input.action.root
            || input.revision != input.action.revision
            || input.scope.config_revision() != input.action.config_revision
            || input.scope.policy_revision() != input.action.policy_revision
        {
            return Err(EditError::InvalidEvidence.into());
        }
        Ok(Self {
            id: input.id,
            scope: input.scope,
            revision: input.revision,
            workspace: input.workspace,
            action: input.action,
        })
    }
}
/// Terminal journal evidence. Receipt durability alone does not imply an applied edit.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum JournalResolution {
    /// Native dispatch was never attempted after recording issuance.
    NotDispatched,
    /// Actual effects could not be established; never replay this operation.
    OutcomeUnknown,
    /// Digest of the separately validated native file/batch receipt.
    Receipt {
        /// Exact commitment to the real receipt, not a frontend success string.
        digest: CaptureDigest,
    },
}
/// Why recovered issuance cannot establish a terminal result.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryReason {
    /// No complete issuance record was found.
    MissingIssue,
    /// The last framed record is incomplete.
    Truncated,
    /// Schema, sequence, identity or integrity chain did not match.
    InvalidRecord,
    /// Issuance or an uncertainty marker has no terminal resolution.
    MissingResolution,
}
/// Detached recovery evidence. No variant can create a live run or editor grant.
pub enum RecoveredJournal {
    /// No trustworthy issuance could be decoded. Treat effects as unknown.
    Unconfirmed(RecoveryReason),
    /// A complete issuance exists, but a terminal resolution is unproven.
    OutcomeUnknown {
        /// Trusted complete issuance prefix.
        issue: JournalIssue,
        /// The unresolved or interrupted part of the journal.
        reason: RecoveryReason,
    },
    /// The complete bounded chain ends in a durable native resolution.
    Resolved {
        /// Original immutable issuance.
        issue: JournalIssue,
        /// Actual terminal evidence; receipt does not itself mean success.
        resolution: JournalResolution,
    },
}
#[derive(Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u8", into = "u8")]
struct Sequence(u8);
impl TryFrom<u8> for Sequence {
    type Error = CoreError;
    fn try_from(value: u8) -> Result<Self, CoreError> {
        if value == 0 || value > limits::EDIT_JOURNAL_RECORDS {
            return Err(EditError::InvalidEvidence.into());
        }
        Ok(Self(value))
    }
}
impl From<Sequence> for u8 {
    fn from(value: Sequence) -> Self {
        value.0
    }
}
impl Sequence {
    fn next(self) -> Result<Self, CoreError> {
        Self::try_from(self.0.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?)
    }
}
#[derive(Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
struct RecordDigest([u8; 32]);
const GENESIS: RecordDigest = RecordDigest([0; 32]);
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: Version,
    sequence: Sequence,
    previous: RecordDigest,
    payload: Payload,
    digest: RecordDigest,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(try_from = "u8", into = "u8")]
struct Version;
impl TryFrom<u8> for Version {
    type Error = CoreError;
    fn try_from(value: u8) -> Result<Self, CoreError> {
        if value == 1 {
            Ok(Self)
        } else {
            Err(EditError::InvalidEvidence.into())
        }
    }
}
impl From<Version> for u8 {
    fn from(_: Version) -> Self {
        1
    }
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum Payload {
    Issue { issue: Box<JournalIssue> },
    Unknown,
    Resolved { resolution: JournalResolution },
}
fn digest(
    sequence: Sequence,
    previous: RecordDigest,
    payload: &Payload,
) -> Result<RecordDigest, CoreError> {
    let body = serde_json::to_vec(payload).map_err(|_| CoreError::InvalidToolOutput)?;
    let mut digest = Sha256::new();
    digest.update(b"kargu-edit-journal-v1");
    digest.update([sequence.0]);
    digest.update(previous.0);
    digest.update(body);
    Ok(RecordDigest(digest.finalize().into()))
}
/// Synced issuance, still awaiting actual editor completion/quiescence.
/// Not cloneable, deserializable or an editor write capability.
/// ```compile_fail
/// use kargu_core::edit::journal::IssuedJournal;
/// fn replay(journal: IssuedJournal) { let copy = journal.clone(); }
/// ```
pub struct IssuedJournal(storage::Writer);
/// A synced uncertainty marker retains journal ownership for a later real receipt.
pub struct UncertainJournal(storage::Writer);
/// Durable terminal evidence. The writer and its exclusive lock have closed.
pub struct JournalCommit {
    id: EditorEditId,
    resolution: JournalResolution,
}
impl JournalCommit {
    /// Native operation identity attached to the terminal record.
    pub fn id(&self) -> &EditorEditId {
        &self.id
    }
    /// Durable resolution; independently classified receipt data is still needed.
    pub fn resolution(&self) -> &JournalResolution {
        &self.resolution
    }
}
impl IssuedJournal {
    /// Worker-only create-new + sync issuance. Existing files are never replaced.
    pub fn create(
        directory: JournalDirectory,
        issue: JournalIssue,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Self, CoreError> {
        checkpoint(cancel, deadline)?;
        storage::Writer::create(directory, issue, cancel, deadline).map(Self)
    }
    /// Persist loss of confirmation without releasing the pending writer.
    pub fn mark_unknown(
        mut self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<UncertainJournal, CoreError> {
        self.0.append(Payload::Unknown, cancel, deadline)?;
        Ok(UncertainJournal(self.0))
    }
    /// Consume the writer only after actual completion or explicit no-dispatch evidence.
    pub fn resolve(
        self,
        resolution: JournalResolution,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<JournalCommit, CoreError> {
        finish(self.0, resolution, cancel, deadline)
    }
}
impl UncertainJournal {
    /// A late real receipt may resolve uncertainty; it cannot issue another write.
    pub fn resolve(
        self,
        resolution: JournalResolution,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<JournalCommit, CoreError> {
        finish(self.0, resolution, cancel, deadline)
    }
}
fn finish(
    mut writer: storage::Writer,
    resolution: JournalResolution,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<JournalCommit, CoreError> {
    writer.append(
        Payload::Resolved {
            resolution: resolution.clone(),
        },
        cancel,
        deadline,
    )?;
    Ok(JournalCommit {
        id: writer.id().clone(),
        resolution,
    })
}
/// Read a bounded journal under a shared lock. Active writers return Busy.
/// Truncation/corruption can only produce unknown evidence, never implicit success.
pub fn recover(
    directory: JournalDirectory,
    id: EditorEditId,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<RecoveredJournal, CoreError> {
    let bytes = storage::read(directory, &id, cancel, deadline)?;
    let mut issue = None;
    let mut resolution = None;
    let mut previous = GENESIS;
    let mut expected = Sequence::try_from(1)?;
    let mut unknown_seen = false;
    let mut problem = None;
    for framed in bytes.split_inclusive(|byte| *byte == b'\n') {
        checkpoint(cancel, deadline)?;
        if framed.last() != Some(&b'\n') {
            problem = Some(RecoveryReason::Truncated);
            break;
        }
        if framed.len() > limits::EDIT_JOURNAL_RECORD_BYTES.saturating_add(1) {
            return Err(CoreError::Limit);
        }
        let Ok(record) = serde_json::from_slice::<Envelope>(framed) else {
            problem = Some(RecoveryReason::InvalidRecord);
            break;
        };
        if record.sequence != expected
            || record.previous != previous
            || record.digest != digest(record.sequence, record.previous, &record.payload)?
            || resolution.is_some()
        {
            problem = Some(RecoveryReason::InvalidRecord);
            break;
        }
        previous = record.digest;
        match record.payload {
            Payload::Issue { issue: new }
                if issue.is_none() && record.sequence.0 == 1 && new.id == id =>
            {
                issue = Some(*new);
            }
            Payload::Unknown if issue.is_some() && !unknown_seen => {
                unknown_seen = true;
            }
            Payload::Resolved { resolution: value } if issue.is_some() => {
                resolution = Some(value);
            }
            _ => {
                problem = Some(RecoveryReason::InvalidRecord);
                break;
            }
        }
        if let Ok(next) = expected.next() {
            expected = next;
        }
    }
    match (issue, resolution, problem) {
        (Some(issue), Some(resolution), None) => {
            Ok(RecoveredJournal::Resolved { issue, resolution })
        }
        (Some(issue), _, reason) => Ok(RecoveredJournal::OutcomeUnknown {
            issue,
            reason: reason.unwrap_or(RecoveryReason::MissingResolution),
        }),
        (None, _, reason) => Ok(RecoveredJournal::Unconfirmed(
            reason.unwrap_or(RecoveryReason::MissingIssue),
        )),
    }
}
