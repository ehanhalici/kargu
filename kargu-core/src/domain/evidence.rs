//! Content evidence shared by editors, sensors and edits: a SHA-256 content
//! hash, a capture commitment and a lexically normalized project-relative
//! path. None of them grants permission to read or write.

use super::error::EditError;
use crate::constants::limits;
use serde::{Deserialize, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};

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

impl CaptureDigest {
    pub(crate) fn capture(bytes: &[u8]) -> Self {
        Self(ContentHash(Sha256::digest(bytes).into()))
    }
}
impl From<[u8; 32]> for ContentHash {
    fn from(digest: [u8; 32]) -> Self {
        Self(digest)
    }
}
