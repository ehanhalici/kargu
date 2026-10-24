//! Bounded direct directory listing, using pinned fds and no-follow entry metadata.

use crate::{
    constants::limits,
    error::CoreError,
    security::{ReadDirectory, Workspace},
};
use nix::{
    dir::Dir,
    fcntl::AtFlags,
    sys::stat::{SFlag, fstatat},
};
use serde::{Deserialize, Serialize};
use std::{
    path::{Component, Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

const OMITTED_NOTICE: &str =
    "\n... (additional entries omitted; narrow the path or raise the entry visit limit)";

/// Raw IPC/configuration boundary; invalid values never become a listing plan.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListFilesInput {
    /// Editor-owned workspace, never taken from model arguments.
    pub root: PathBuf,
    /// Optional root-relative or contained absolute directory.
    pub path: Option<PathBuf>,
    /// Exact shared exclusion names; preserve the legacy basename filter.
    pub skip_directories: Vec<String>,
    /// All inspected entries, including excluded names, have this separate budget.
    pub max_entries: usize,
}

struct EntryVisitLimit(usize);
#[derive(Default)]
struct EntryVisits(usize);
#[derive(Default)]
struct OutputBytes(usize);
struct Exclusions(Vec<String>);

impl TryFrom<usize> for EntryVisitLimit {
    type Error = CoreError;
    fn try_from(value: usize) -> Result<Self, CoreError> {
        if value > limits::SEARCH_ENTRIES {
            return Err(CoreError::Limit);
        }
        Ok(Self(value))
    }
}

impl TryFrom<Vec<String>> for Exclusions {
    type Error = CoreError;
    fn try_from(value: Vec<String>) -> Result<Self, CoreError> {
        if value.len() > 64
            || value.iter().any(|name| {
                name.is_empty()
                    || name.len() > 256
                    || name == "."
                    || name == ".."
                    || name.contains(['/', '\0'])
            })
        {
            return Err(CoreError::InvalidValue {
                field: "ListingExclusions",
            });
        }
        Ok(Self(value))
    }
}

/// Captured one-shot operation; IO execution consumes its validated state.
pub struct ListFilesPlan {
    workspace: Workspace,
    directory: ReadDirectory,
    exclusions: Exclusions,
    limit: EntryVisitLimit,
}

impl TryFrom<ListFilesInput> for ListFilesPlan {
    type Error = CoreError;
    fn try_from(input: ListFilesInput) -> Result<Self, CoreError> {
        let limit = EntryVisitLimit::try_from(input.max_entries)?;
        let exclusions = Exclusions::try_from(input.skip_directories)?;
        validate_path(&input.root)?;
        let target = input.path.unwrap_or_default();
        validate_path(&target)?;
        if !input.root.is_absolute() {
            return Err(CoreError::InvalidValue {
                field: "ListingRoot",
            });
        }
        let workspace = Workspace::try_from(input.root)?;
        let directory = workspace.open_read_directory(&target)?;
        Ok(Self {
            workspace,
            directory,
            exclusions,
            limit,
        })
    }
}

fn validate_path(path: &Path) -> Result<(), CoreError> {
    if path.as_os_str().len() > limits::SEARCH_PATH_BYTES
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return Err(CoreError::InvalidValue {
            field: "ListingPath",
        });
    }
    Ok(())
}

/// An entry's own kind; symbolic links are never classified by following targets.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    /// Real directory.
    Directory,
    /// Regular file.
    File,
    /// Symbolic link (its target is not inspected).
    Symlink,
    /// Socket, device, FIFO or another non-regular entry.
    Other,
}
impl EntryKind {
    fn label(self) -> &'static str {
        match self {
            Self::Directory => "[DIR] ",
            Self::File => "[FILE]",
            Self::Symlink => "[LINK]",
            Self::Other => "[OTHER]",
        }
    }
}

/// One project-relative entry, not an absolute path or a symlink destination.
#[derive(Serialize)]
pub struct DirectoryEntry {
    /// Valid UTF-8 project-relative name without record delimiters.
    pub path: String,
    /// No-follow entry metadata.
    pub kind: EntryKind,
}

/// Native typed result and its bounded legacy-compatible display.
#[derive(Serialize)]
pub struct ListFilesResult {
    /// Immediate entries only, sorted by display label and relative path.
    pub entries: Vec<DirectoryEntry>,
    /// Human-readable result; formatting remains in Rust.
    pub text: String,
    /// A visit, result or output-byte limit prevented an exhaustive listing.
    pub truncated: bool,
}

#[derive(Default)]
struct ListingBuffer {
    entries: Vec<DirectoryEntry>,
    visits: EntryVisits,
    bytes: OutputBytes,
}

impl ListFilesPlan {
    /// Execute on a blocking worker; the actor retains admission until drain.
    pub fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ListFilesResult, CoreError> {
        self.check_live(cancel, deadline)?;
        let mut directory =
            Dir::from_fd(self.directory.file.try_clone()?.into()).map_err(std::io::Error::from)?;
        let mut buffer = ListingBuffer::default();
        let mut truncated = false;
        for item in directory.iter() {
            self.check_cancel(cancel, deadline)?;
            let item = item.map_err(std::io::Error::from)?;
            if !self.visit(item.file_name(), &mut buffer)? {
                truncated = true;
                break;
            }
        }
        self.check_live(cancel, deadline)?;
        Ok(render(buffer.entries, truncated))
    }

    fn visit(&self, name: &std::ffi::CStr, buffer: &mut ListingBuffer) -> Result<bool, CoreError> {
        if matches!(name.to_bytes(), b"." | b"..") {
            return Ok(true);
        }
        if buffer.visits.0 >= self.limit.0 {
            return Ok(false);
        }
        buffer.visits.0 = buffer.visits.0.saturating_add(1);
        match self.entry(name)? {
            Some(entry) => retain(&mut buffer.entries, &mut buffer.bytes, entry),
            None => Ok(true),
        }
    }

    fn entry(&self, name: &std::ffi::CStr) -> Result<Option<DirectoryEntry>, CoreError> {
        let name = name.to_str().map_err(|_| CoreError::InvalidValue {
            field: "ListingEntry",
        })?;
        if name.contains(['\n', '\r']) {
            return Err(CoreError::InvalidValue {
                field: "ListingEntry",
            });
        }
        if self.exclusions.0.iter().any(|excluded| excluded == name) {
            return Ok(None);
        }
        let kind = self.classify(name)?;
        let relative = self
            .directory
            .path
            .strip_prefix(self.workspace.path())
            .map_err(|_| CoreError::Rejected)?;
        let path = relative
            .join(name)
            .to_str()
            .ok_or(CoreError::InvalidValue {
                field: "ListingEntry",
            })?
            .to_owned();
        if path.contains(['\n', '\r']) {
            return Err(CoreError::InvalidValue {
                field: "ListingEntry",
            });
        }
        Ok(Some(DirectoryEntry { path, kind }))
    }

    fn classify(&self, name: &str) -> Result<EntryKind, CoreError> {
        let metadata = fstatat(&self.directory.file, name, AtFlags::AT_SYMLINK_NOFOLLOW)
            .map_err(std::io::Error::from)?;
        Ok(
            match SFlag::from_bits_truncate(metadata.st_mode) & SFlag::S_IFMT {
                SFlag::S_IFDIR => EntryKind::Directory,
                SFlag::S_IFREG => EntryKind::File,
                SFlag::S_IFLNK => EntryKind::Symlink,
                _ => EntryKind::Other,
            },
        )
    }

    fn check_live(&self, cancel: &CancellationToken, deadline: Instant) -> Result<(), CoreError> {
        self.check_cancel(cancel, deadline)?;
        self.workspace.revalidate()?;
        self.directory.revalidate()
    }

    fn check_cancel(&self, cancel: &CancellationToken, deadline: Instant) -> Result<(), CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        Ok(())
    }
}

fn retain(
    entries: &mut Vec<DirectoryEntry>,
    bytes: &mut OutputBytes,
    entry: DirectoryEntry,
) -> Result<bool, CoreError> {
    let total = bytes
        .0
        .checked_add(entry.path.len())
        .and_then(|n| n.checked_add(entry.kind.label().len().saturating_add(2)))
        .ok_or(CoreError::ArithmeticOverflow)?;
    let retained_budget = limits::SEARCH_RESULT_BYTES.saturating_sub(OMITTED_NOTICE.len());
    if entries.len() >= limits::LIST_RESULTS || total > retained_budget {
        return Ok(false);
    }
    bytes.0 = total;
    entries.push(entry);
    Ok(true)
}

fn render(mut entries: Vec<DirectoryEntry>, truncated: bool) -> ListFilesResult {
    entries.sort_by(|a, b| (a.kind.label(), &a.path).cmp(&(b.kind.label(), &b.path)));
    let mut text = entries
        .iter()
        .map(|entry| format!("{} {}", entry.kind.label(), entry.path))
        .collect::<Vec<_>>()
        .join("\n");
    if truncated {
        text.push_str(OMITTED_NOTICE);
    } else if entries.is_empty() {
        text.push_str("(empty directory)");
    }
    ListFilesResult {
        entries,
        text,
        truncated,
    }
}
