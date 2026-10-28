//! Bounded, unit-specific source text, target paths and content evidence.
//!
//! Old/new coordinates cannot be interchanged even when their integer is equal:
//! ```compile_fail
//! use kargu_core::edit::types::{OldLine, NewLine};
//! fn interchange(old: OldLine) -> NewLine { old }
//! ```

use super::EditError;
use crate::constants::limits;
use serde::{Deserialize, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};
use zeroize::Zeroizing;

/// Captured decoded editor text; construction never reads or changes a file.
/// No Debug implementation: diagnostics must not print source contents.
/// The bounded boundary cannot be bypassed with a tuple constructor:
/// ```compile_fail
/// use kargu_core::edit::types::EditText;
/// let text = EditText("unbounded source".into());
/// ```
#[derive(Clone, Deserialize)]
#[serde(try_from = "String")]
pub struct EditText(Zeroizing<String>);
impl TryFrom<String> for EditText {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::from_sensitive(Zeroizing::new(value))
    }
}
impl EditText {
    pub(crate) fn into_sensitive(self) -> Zeroizing<String> {
        self.0
    }
    pub(crate) fn from_sensitive(value: Zeroizing<String>) -> Result<Self, EditError> {
        if value.len() > limits::EDIT_TEXT_BYTES {
            return Err(EditError::Limit);
        }
        Ok(Self(value))
    }
}
impl EditText {
    /// Borrow decoded UTF-8 text, independently of the editor's disk encoding.
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }
    /// Hash exactly the captured text; Unicode and trailing newlines are retained.
    pub fn hash(&self) -> ContentHash {
        ContentHash(Sha256::digest(self.as_str().as_bytes()).into())
    }
}
impl Serialize for EditText {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

/// SHA-256 of decoded text; a digest alone never grants permission to edit.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize)]
#[serde(try_from = "String")]
pub struct ContentHash([u8; 32]);
impl TryFrom<String> for ContentHash {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() != 64 {
            return Err(EditError::InvalidEvidence);
        }
        let mut output = [0; 32];
        for (slot, pair) in output.iter_mut().zip(value.as_bytes().chunks_exact(2)) {
            let high = digit(*pair.first().ok_or(EditError::InvalidEvidence)?)?;
            let low = digit(*pair.get(1).ok_or(EditError::InvalidEvidence)?)?;
            *slot = high
                .checked_mul(16)
                .and_then(|n| n.checked_add(low))
                .ok_or(EditError::InvalidEvidence)?;
        }
        Ok(Self(output))
    }
}
fn digit(value: u8) -> Result<u8, EditError> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(value - b'a' + 10),
        _ => Err(EditError::InvalidEvidence),
    }
}
impl Serialize for ContentHash {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(
            &self
                .0
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>(),
        )
    }
}

/// Lexically normalized project-relative target. Canonical grant checks follow
/// on the owned I/O worker; this type does not claim filesystem confinement.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct EditPath(String);
impl TryFrom<String> for EditPath {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > limits::SEARCH_PATH_BYTES || value.chars().any(char::is_control) {
            return Err(EditError::InvalidPath);
        }
        let mut clean = PathBuf::new();
        for part in Path::new(&value).components() {
            match part {
                Component::Normal(name) if name != ".git" && name != ".kargu.patch" => {
                    clean.push(name)
                }
                Component::CurDir => {}
                _ => return Err(EditError::InvalidPath),
            }
        }
        let value = clean.to_str().ok_or(EditError::InvalidPath)?.to_owned();
        if value.is_empty() {
            return Err(EditError::InvalidPath);
        }
        Ok(Self(value))
    }
}
impl From<EditPath> for String {
    fn from(value: EditPath) -> Self {
        value.0
    }
}
impl EditPath {
    /// Borrow a literal root-relative pathname, never a shell argument string.
    pub fn as_path(&self) -> &Path {
        Path::new(&self.0)
    }
    /// Borrow its normalized UTF-8 wire spelling.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

macro_rules! count {
    ($name:ident, $bound:expr, $doc:literal) => {
        #[doc=$doc]
        #[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
        #[serde(try_from = "usize")]
        pub struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = EditError;
            fn try_from(value: usize) -> Result<Self, Self::Error> {
                if value > $bound {
                    return Err(EditError::Limit);
                }
                Ok(Self(value))
            }
        }
        impl $name {
            /// Read the count in its declared unit at a rendering/DTO boundary.
            pub fn get(self) -> usize {
                self.0
            }
        }
    };
}
count!(
    HunkCount,
    limits::EDIT_HUNKS,
    "Count of proposed/applied hunks; not a line offset."
);
count!(
    OldLineCount,
    limits::EDIT_PATCH_LINES,
    "Number of old-side hunk body lines."
);
count!(
    NewLineCount,
    limits::EDIT_PATCH_LINES,
    "Number of new-side hunk body lines."
);
count!(
    OldLine,
    limits::EDIT_TEXT_BYTES,
    "Old-side Unified Diff start coordinate; zero denotes an empty range."
);
count!(
    NewLine,
    limits::EDIT_TEXT_BYTES,
    "New-side Unified Diff start coordinate; zero denotes an empty range."
);

/// Review policy captured with an immutable editor intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewMode {
    /// Apply under captured auto policy without an interactive decision.
    Auto,
    /// Keep a pending review while its caller may continue.
    Async,
    /// Keep the caller pending until an explicit review decision.
    Blocking,
}
/// Explicit editor buffer-only or disk-save policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SavePolicy {
    /// Change only the live buffer.
    BufferOnly,
    /// Save through the editor and report actual hook effects.
    Save,
}

/// Source owner identity, distinct from an application/session or editor edit ID.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct EditorSourceId(uuid::Uuid);
impl TryFrom<String> for EditorSourceId {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, EditError> {
        uuid::Uuid::parse_str(
            value
                .strip_prefix("editor_source_")
                .ok_or(EditError::InvalidEvidence)?,
        )
        .map(Self)
        .map_err(|_| EditError::InvalidEvidence)
    }
}
impl From<EditorSourceId> for String {
    fn from(value: EditorSourceId) -> Self {
        format!("editor_source_{}", value.0)
    }
}

/// Native review revision; a different revision cannot reuse the same decision.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct EditorRevision(u64);
impl TryFrom<u64> for EditorRevision {
    type Error = EditError;
    fn try_from(value: u64) -> Result<Self, EditError> {
        if value == 0 {
            Err(EditError::InvalidEvidence)
        } else {
            Ok(Self(value))
        }
    }
}
/// Commitment to captured document/disk evidence, not a content hash or authority.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(transparent)]
pub struct CaptureDigest(ContentHash);
impl TryFrom<String> for CaptureDigest {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, EditError> {
        ContentHash::try_from(value).map(Self)
    }
}

#[derive(Clone, Eq, Hash, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub(crate) struct EditorEditId(uuid::Uuid);
impl EditorEditId {
    pub(crate) fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
impl TryFrom<String> for EditorEditId {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, EditError> {
        uuid::Uuid::parse_str(
            value
                .strip_prefix("editor_edit_")
                .ok_or(EditError::InvalidEvidence)?,
        )
        .map(Self)
        .map_err(|_| EditError::InvalidEvidence)
    }
}
impl From<EditorEditId> for String {
    fn from(value: EditorEditId) -> Self {
        format!("editor_edit_{}", value.0)
    }
}
impl CaptureDigest {
    pub(crate) fn capture(bytes: &[u8]) -> Self {
        Self(ContentHash(Sha256::digest(bytes).into()))
    }
}
