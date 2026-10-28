//! Immutable editor intent. Capture hashes and IDs never substitute for permission.
use super::{
    EditError,
    types::{
        CaptureDigest, EditPath, EditText, EditorRevision, EditorSourceId, ReviewMode, SavePolicy,
    },
};
use crate::{
    application::{Mode, RunHandle},
    constants::limits,
    domain::{ConfigRevision, PolicyRevision},
    error::CoreError,
    security::Workspace,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

/// A closed file intent with decoded text and a captured-evidence commitment.
/// No Debug/Serialize implementation can implicitly disclose source bodies.
pub enum EditorFileInput {
    /// An absent file becomes a regular file; even empty creation is an effect.
    Add {
        /// Validated relative target.
        path: EditPath,
        /// Full proposed decoded text.
        proposed: EditText,
        /// Commitment to captured absence/document evidence.
        capture: CaptureDigest,
    },
    /// Replace a complete captured version after live preflight.
    Update {
        /// Validated relative target.
        path: EditPath,
        /// Full captured base text.
        base: EditText,
        /// Full proposed decoded text.
        proposed: EditText,
        /// Commitment to the captured source evidence.
        capture: CaptureDigest,
    },
    /// Delete a captured regular file; only auto review policy allows this action.
    Delete {
        /// Validated relative target.
        path: EditPath,
        /// Full captured base text.
        base: EditText,
        /// Commitment to the captured source evidence.
        capture: CaptureDigest,
    },
}
impl EditorFileInput {
    /// Borrow the exact qualified target without resolving another path.
    pub fn path(&self) -> &EditPath {
        match self {
            Self::Add { path, .. } | Self::Update { path, .. } | Self::Delete { path, .. } => path,
        }
    }
    fn bytes(&self) -> Result<usize, EditError> {
        match self {
            Self::Add { proposed, .. } => Ok(proposed.as_str().len()),
            Self::Delete { base, .. } => Ok(base.as_str().len()),
            Self::Update { base, proposed, .. } => base
                .as_str()
                .len()
                .checked_add(proposed.as_str().len())
                .ok_or(EditError::Limit),
        }
    }
    fn metadata(&self) -> Value {
        match self {
            Self::Add {
                path,
                proposed,
                capture,
            } => {
                json!({"operation":"add","path":path,"proposed_hash":proposed.hash(),"capture":capture})
            }
            Self::Update {
                path,
                base,
                proposed,
                capture,
            } => {
                json!({"operation":"update","path":path,"base_hash":base.hash(),"proposed_hash":proposed.hash(),"capture":capture})
            }
            Self::Delete {
                path,
                base,
                capture,
            } => {
                json!({"operation":"delete","path":path,"base_hash":base.hash(),"capture":capture})
            }
        }
    }
}
/// Boundary input from the owned proposal/capture service, not an execution grant.
/// Filesystem capture and text hashing must run on a bounded worker.
pub struct EditorActionInput {
    /// Captured source owner, separate from the native execution run scope.
    pub source: EditorSourceId,
    /// Captured proposal/review revision.
    pub revision: EditorRevision,
    /// Native pinned root shared with the actual run settings.
    pub workspace: Workspace,
    /// Frozen configuration revision.
    pub config_revision: ConfigRevision,
    /// Frozen policy revision.
    pub policy_revision: PolicyRevision,
    /// Frozen review policy; auto is the only automatic-consent case.
    pub review_mode: ReviewMode,
    /// Explicit editor save behavior.
    pub save_policy: SavePolicy,
    /// Complete ordered file intentions; no path may occur twice.
    pub files: Vec<EditorFileInput>,
}
/// Consumed immutable action held by the shared permission ledger.
/// It is an intent, never an editor write capability or proof of live preflight.
pub struct EditorAction {
    input: EditorActionInput,
    commitment: [u8; 32],
    metadata: Value,
}
impl TryFrom<EditorActionInput> for EditorAction {
    type Error = CoreError;
    fn try_from(input: EditorActionInput) -> Result<Self, CoreError> {
        if input.files.is_empty() || input.files.len() > limits::EDIT_FILES {
            return Err(EditError::Limit.into());
        }
        let mut paths = BTreeSet::new();
        let mut retained = RetainedBytes(0);
        for file in &input.files {
            if !paths.insert(file.path()) {
                return Err(EditError::InvalidEvidence.into());
            }
            retained.include(file)?;
        }
        let files: Vec<_> = input.files.iter().map(EditorFileInput::metadata).collect();
        let root = input
            .workspace
            .path()
            .to_str()
            .ok_or(EditError::InvalidPath)?;
        let metadata = json!({"source":input.source,"revision":input.revision,"root":root,
            "config_revision":input.config_revision,"policy_revision":input.policy_revision,"review_mode":input.review_mode,
            "save_policy":input.save_policy,"files":files});
        let bytes = serde_json::to_vec(&metadata).map_err(|_| CoreError::Limit)?;
        let commitment = Sha256::digest(&bytes).into();
        Ok(Self {
            input,
            metadata,
            commitment,
        })
    }
}
struct RetainedBytes(usize);
impl RetainedBytes {
    fn include(&mut self, file: &EditorFileInput) -> Result<(), EditError> {
        let next = self.0.checked_add(file.bytes()?).ok_or(EditError::Limit)?;
        if next > limits::EDIT_BUFFER_BYTES {
            return Err(EditError::Limit);
        }
        self.0 = next;
        Ok(())
    }
}
impl EditorAction {
    /// Borrow detached, source-free review metadata computed on the capture worker.
    pub fn metadata(&self) -> &Value {
        &self.metadata
    }
    /// The immutable review policy.
    pub fn review_mode(&self) -> ReviewMode {
        self.input.review_mode
    }
    /// The immutable native revision.
    pub fn revision(&self) -> EditorRevision {
        self.input.revision
    }
    /// Explicitly access intended source text at the trusted editor port only.
    pub fn files(&self) -> &[EditorFileInput] {
        &self.input.files
    }
    pub(crate) fn commitment(&self) -> &[u8; 32] {
        &self.commitment
    }
    pub(crate) fn matches_run(&self, run: &RunHandle) -> bool {
        run.settings().mode == Mode::Agent
            && self.input.workspace.same_capture(&run.settings().workspace)
            && self.input.config_revision == run.scope().config_revision()
            && self.input.policy_revision == run.scope().policy_revision()
    }
    pub(crate) fn permits_deletion(&self) -> bool {
        self.input.review_mode == ReviewMode::Auto
            || !self
                .input
                .files
                .iter()
                .any(|f| matches!(f, EditorFileInput::Delete { .. }))
    }
}
