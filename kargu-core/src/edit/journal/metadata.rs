//! Closed source-free journal metadata; source-bearing fields cannot deserialize.
use crate::{
    constants::limits,
    domain::{ConfigRevision, PolicyRevision},
    edit::{
        EditError,
        types::{
            CaptureDigest, ContentHash, EditPath, EditorRevision, EditorSourceId, ReviewMode,
            SavePolicy,
        },
    },
    error::CoreError,
};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, path::PathBuf};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StoredAction {
    source: EditorSourceId,
    pub(super) revision: EditorRevision,
    pub(super) root: PathBuf,
    pub(super) config_revision: ConfigRevision,
    pub(super) policy_revision: PolicyRevision,
    review_mode: ReviewMode,
    save_policy: SavePolicy,
    files: StoredFiles,
}
#[derive(Serialize, Deserialize)]
#[serde(try_from = "Vec<StoredFile>")]
struct StoredFiles(Vec<StoredFile>);
impl TryFrom<Vec<StoredFile>> for StoredFiles {
    type Error = CoreError;
    fn try_from(files: Vec<StoredFile>) -> Result<Self, CoreError> {
        if files.is_empty() || files.len() > limits::EDIT_FILES {
            return Err(CoreError::Limit);
        }
        let mut seen = BTreeSet::new();
        for file in &files {
            if !seen.insert(file.path()) {
                return Err(EditError::InvalidEvidence.into());
            }
        }
        Ok(Self(files))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum StoredFile {
    Add {
        path: EditPath,
        proposed_hash: ContentHash,
        capture: CaptureDigest,
    },
    Update {
        path: EditPath,
        base_hash: ContentHash,
        proposed_hash: ContentHash,
        capture: CaptureDigest,
    },
    Delete {
        path: EditPath,
        base_hash: ContentHash,
        capture: CaptureDigest,
    },
}
impl StoredFile {
    fn path(&self) -> &EditPath {
        match self {
            Self::Add { path, .. } | Self::Update { path, .. } | Self::Delete { path, .. } => path,
        }
    }
}
