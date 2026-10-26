//! Bounded numbered text excerpts; editor snapshots and disk share one renderer.

mod decode;
mod read;
mod render;

use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use zeroize::Zeroizing;

macro_rules! limit {
    ($name:ident, $maximum:expr) => {
        #[derive(Deserialize)]
        #[serde(try_from = "usize")]
        struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = CoreError;
            fn try_from(value: usize) -> Result<Self, CoreError> {
                if value > $maximum {
                    Err(CoreError::Limit)
                } else {
                    Ok(Self(value))
                }
            }
        }
    };
}
limit!(DiskByteBudget, 64 * 1024 * 1024);
limit!(ScanCharBudget, 64 * 1024 * 1024);
limit!(ExcerptCharBudget, 131072);

#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "u64")]
struct LineNumber(u64);
impl TryFrom<u64> for LineNumber {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 || value > i64::MAX as u64 {
            Err(CoreError::InvalidValue {
                field: "LineNumber",
            })
        } else {
            Ok(Self(value))
        }
    }
}
impl LineNumber {
    fn next(self) -> Result<Self, CoreError> {
        Self::try_from(self.0.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?)
    }
}
#[derive(Deserialize)]
#[serde(try_from = "WindowDto")]
struct Window {
    from: LineNumber,
    to: Option<LineNumber>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WindowDto {
    from: LineNumber,
    to: Option<LineNumber>,
}
impl TryFrom<WindowDto> for Window {
    type Error = CoreError;
    fn try_from(value: WindowDto) -> Result<Self, CoreError> {
        if value.to.is_some_and(|to| to.0 < value.from.0) {
            return Err(CoreError::InvalidValue {
                field: "LineWindow",
            });
        }
        Ok(Self {
            from: value.from,
            to: value.to,
        })
    }
}

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct DisplayPath(String);
impl TryFrom<String> for DisplayPath {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty() || value.len() > 4096 || value.contains('\0') {
            return Err(CoreError::InvalidValue {
                field: "FileDisplayPath",
            });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(try_from = "PathBuf")]
struct FilePath(PathBuf);
impl TryFrom<PathBuf> for FilePath {
    type Error = CoreError;
    fn try_from(value: PathBuf) -> Result<Self, CoreError> {
        super::command::validate_path(&value)?;
        if value.as_os_str().is_empty() || value.as_os_str().as_encoded_bytes().contains(&0) {
            return Err(CoreError::InvalidValue { field: "FilePath" });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Source {
    Disk {
        root: FilePath,
        path: FilePath,
    },
    Editor {
        text: String,
        probe: String,
        from_available: bool,
        complete: bool,
    },
}
/// Closed read-only request; no process, decoder callback or mutable edit action.
#[derive(Deserialize)]
#[serde(try_from = "ReadFileDto")]
pub struct ReadFileInput {
    display_path: DisplayPath,
    window: Window,
    max_bytes: DiskByteBudget,
    scan_chars: ScanCharBudget,
    output_chars: ExcerptCharBudget,
    source: Source,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadFileDto {
    display_path: DisplayPath,
    window: Window,
    max_bytes: DiskByteBudget,
    scan_chars: ScanCharBudget,
    output_chars: ExcerptCharBudget,
    source: Source,
}
impl TryFrom<ReadFileDto> for ReadFileInput {
    type Error = CoreError;
    fn try_from(value: ReadFileDto) -> Result<Self, CoreError> {
        match &value.source {
            Source::Disk { root, path } => {
                if value.max_bytes.0 == 0 {
                    return Err(CoreError::InvalidValue {
                        field: "DisabledFileReadBudget",
                    });
                }
                if !root.0.is_absolute() || !root.0.join(&path.0).starts_with(&root.0) {
                    return Err(CoreError::Rejected);
                }
            }
            Source::Editor { text, probe, .. } => {
                if probe.chars().count() > 1000
                    || text.chars().count() > value.output_chars.0.saturating_add(1)
                    || text.chars().count() > value.scan_chars.0
                    || probe.contains('\0')
                {
                    return Err(CoreError::InvalidValue {
                        field: "EditorFileSnapshot",
                    });
                }
            }
        }
        Ok(Self {
            display_path: value.display_path,
            window: value.window,
            max_bytes: value.max_bytes,
            scan_chars: value.scan_chars,
            output_chars: value.output_chars,
            source: value.source,
        })
    }
}
/// Completed, bounded excerpt. Counts describe actual reads, never a full scan estimate.
#[derive(Serialize)]
pub struct FileExcerpt {
    /// Numbered model-facing text including explicit unknown/truncated markers.
    pub text: String,
    /// Disk bytes actually read; editor snapshots report zero.
    pub bytes_read: usize,
    /// Whether a complete scan reached the end of the source.
    pub truncated: bool,
}
struct Snapshot {
    text: Zeroizing<String>,
    available: bool,
    complete: bool,
}
