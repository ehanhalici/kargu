//! Exact upload, editor identity and native filesystem evidence boundaries.
use crate::{
    application::Mode,
    constants::limits,
    domain::{ConfigRevision, PolicyRevision},
    edit::{
        EditError,
        types::{EditPath, EditText},
    },
};
use serde::{Deserialize, Serialize};
use std::{os::unix::fs::MetadataExt, path::PathBuf};

macro_rules! identity {
    ($name:ident,$prefix:literal) => {
        #[derive(Clone, Debug, Eq, Hash, PartialEq, Deserialize, Serialize)]
        #[serde(try_from = "String", into = "String")]
        pub(crate) struct $name(uuid::Uuid);
        impl TryFrom<String> for $name {
            type Error = EditError;
            fn try_from(v: String) -> Result<Self, Self::Error> {
                uuid::Uuid::parse_str(v.strip_prefix($prefix).ok_or(EditError::InvalidEvidence)?)
                    .map(Self)
                    .map_err(|_| EditError::InvalidEvidence)
            }
        }
        impl From<$name> for String {
            fn from(v: $name) -> Self {
                format!("{}{}", $prefix, v.0)
            }
        }
    };
}
identity!(PreparationId, "edit_prepare_");
impl PreparationId {
    pub(super) fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
pub(crate) use crate::edit::types::EditorSourceId as OriginId;
identity!(DocumentId, "editor_document_");
macro_rules! count {
    ($name:ident,$limit:expr) => {
        #[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
        #[serde(try_from = "usize")]
        pub(super) struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = EditError;
            fn try_from(v: usize) -> Result<Self, Self::Error> {
                if v > $limit {
                    Err(EditError::Limit)
                } else {
                    Ok(Self(v))
                }
            }
        }
        impl $name {
            pub(super) fn get(self) -> usize {
                self.0
            }
        }
    };
}
count!(TextBytes, limits::EDIT_TEXT_BYTES);
count!(TextOffset, limits::EDIT_TEXT_BYTES);
count!(FileCursor, limits::EDIT_FILES);
count!(FileCount, limits::EDIT_FILES);
count!(RetainedBytes, limits::EDIT_BUFFER_BYTES);
impl RetainedBytes {
    pub(super) fn include(&mut self, text: &EditText) -> Result<(), EditError> {
        *self = Self::try_from(
            self.get()
                .checked_add(text.as_str().len())
                .ok_or(EditError::Limit)?,
        )?;
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub(super) struct DocumentTick(u64);
impl TryFrom<u64> for DocumentTick {
    type Error = EditError;
    fn try_from(v: u64) -> Result<Self, Self::Error> {
        if v == 0 || v > i64::MAX as u64 {
            Err(EditError::InvalidEvidence)
        } else {
            Ok(Self(v))
        }
    }
}
macro_rules! stat {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
        #[serde(transparent)]
        pub(super) struct $name(u64);
    };
}
stat!(Device);
stat!(Inode);
stat!(DiskBytes);
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub(super) struct UnixNanos(i128);
impl TryFrom<String> for UnixNanos {
    type Error = EditError;
    fn try_from(v: String) -> Result<Self, Self::Error> {
        if v.len() > 40 {
            return Err(EditError::InvalidEvidence);
        }
        v.parse::<i128>()
            .map(Self)
            .map_err(|_| EditError::InvalidEvidence)
    }
}
impl From<UnixNanos> for String {
    fn from(v: UnixNanos) -> Self {
        v.0.to_string()
    }
}
impl UnixNanos {
    fn from_parts(s: i64, ns: i64) -> Result<Self, EditError> {
        i128::from(s)
            .checked_mul(1_000_000_000)
            .and_then(|n| n.checked_add(i128::from(ns)))
            .map(Self)
            .ok_or(EditError::InvalidEvidence)
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DiskVersion {
    device: Device,
    inode: Inode,
    bytes: DiskBytes,
    mtime_ns: UnixNanos,
    ctime_ns: UnixNanos,
}
impl DiskVersion {
    pub(super) fn capture(m: &std::fs::Metadata) -> Result<Self, EditError> {
        Ok(Self {
            device: Device(m.dev()),
            inode: Inode(m.ino()),
            bytes: DiskBytes(m.len()),
            mtime_ns: UnixNanos::from_parts(m.mtime(), m.mtime_nsec())?,
            ctime_ns: UnixNanos::from_parts(m.ctime(), m.ctime_nsec())?,
        })
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum DiskState {
    Absent {},
    File { version: DiskVersion },
}
#[derive(Clone, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub(super) struct Coding(String);
impl TryFrom<String> for Coding {
    type Error = EditError;
    fn try_from(v: String) -> Result<Self, Self::Error> {
        if v.is_empty() || v.len() > 128 || v.chars().any(char::is_control) {
            Err(EditError::InvalidEvidence)
        } else {
            Ok(Self(v))
        }
    }
}
impl From<Coding> for String {
    fn from(v: Coding) -> Self {
        v.0
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct LiveDocument {
    pub id: DocumentId,
    pub tick: DocumentTick,
    pub bytes: TextBytes,
    pub coding: Coding,
    pub dirty: bool,
    pub read_only: bool,
    pub disk: DiskState,
}
pub(crate) use crate::edit::types::{ReviewMode, SavePolicy};
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum Intent {
    Replace {
        path: EditPath,
        old_bytes: TextBytes,
        new_bytes: TextBytes,
    },
    Write {
        path: EditPath,
        new_bytes: TextBytes,
    },
    Patch {
        patch_bytes: TextBytes,
    },
}
impl Intent {
    pub(super) fn path(&self) -> Option<&EditPath> {
        match self {
            Self::Replace { path, .. } | Self::Write { path, .. } => Some(path),
            Self::Patch { .. } => None,
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Begin {
    pub origin_id: OriginId,
    pub root: PathBuf,
    pub mode: Mode,
    pub intent: Intent,
    pub live: Option<LiveDocument>,
    pub config_revision: ConfigRevision,
    pub policy_revision: PolicyRevision,
    pub review_mode: ReviewMode,
    pub save_policy: SavePolicy,
}
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(try_from = "usize")]
pub(super) struct FileIndex(usize);
impl TryFrom<usize> for FileIndex {
    type Error = EditError;
    fn try_from(v: usize) -> Result<Self, EditError> {
        if v < limits::EDIT_FILES {
            Ok(Self(v))
        } else {
            Err(EditError::Limit)
        }
    }
}
impl FileIndex {
    pub(super) fn get(self) -> usize {
        self.0
    }
}
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub(super) enum Part {
    Old,
    New,
    Document,
    Patch,
    DocumentAt(FileIndex),
}
impl TryFrom<String> for Part {
    type Error = EditError;
    fn try_from(v: String) -> Result<Self, EditError> {
        match v.as_str() {
            "old" => Ok(Self::Old),
            "new" => Ok(Self::New),
            "document" => Ok(Self::Document),
            "patch" => Ok(Self::Patch),
            _ => {
                let n = v
                    .strip_prefix("document:")
                    .ok_or(EditError::InvalidEvidence)?;
                let index = n.parse::<usize>().map_err(|_| EditError::InvalidEvidence)?;
                if index.to_string() != n {
                    return Err(EditError::InvalidEvidence);
                }
                Ok(Self::DocumentAt(FileIndex::try_from(index)?))
            }
        }
    }
}
impl From<Part> for String {
    fn from(v: Part) -> Self {
        match v {
            Part::Old => "old".into(),
            Part::New => "new".into(),
            Part::Document => "document".into(),
            Part::Patch => "patch".into(),
            Part::DocumentAt(index) => format!("document:{}", index.get()),
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Targets {
    pub origin_id: OriginId,
    pub preparation_id: PreparationId,
    pub offset: FileCursor,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Document {
    pub origin_id: OriginId,
    pub preparation_id: PreparationId,
    pub path: EditPath,
    pub document: LiveDocument,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Ticket {
    pub origin_id: OriginId,
    pub preparation_id: PreparationId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Append {
    pub origin_id: OriginId,
    pub preparation_id: PreparationId,
    pub part: Part,
    pub offset: TextOffset,
    pub text: Chunk,
}
#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(super) struct Chunk(pub zeroize::Zeroizing<String>);
impl TryFrom<String> for Chunk {
    type Error = EditError;
    fn try_from(v: String) -> Result<Self, Self::Error> {
        let v = zeroize::Zeroizing::new(v);
        if v.is_empty() || v.len() > limits::EDIT_PAGE_BYTES {
            Err(EditError::Limit)
        } else {
            Ok(Self(v))
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Read {
    pub origin_id: OriginId,
    pub preparation_id: PreparationId,
    pub part: PreparedPart,
    pub offset: TextOffset,
    pub file: Option<FileIndex>,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum PreparedPart {
    Base,
    Proposed,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Close {
    pub origin_id: OriginId,
}
