//! Bounded native file discovery. No subprocess, file-content read or editor wait.
//!
//! Hidden source files are included. The explicit client directory exclusions
//! and compiled/backup artifact policy apply consistently, without depending on
//! installed fd/rg versions or machine-global Git ignore configuration.

use crate::{constants::limits, error::CoreError, security::Workspace};
use globset::{GlobBuilder, GlobMatcher};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Component, Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

macro_rules! bounded_limit {
    ($name:ident, $max:expr) => {
        struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = CoreError;
            fn try_from(value: usize) -> Result<Self, CoreError> {
                if value > $max {
                    return Err(CoreError::Limit);
                }
                Ok(Self(value))
            }
        }
    };
}
bounded_limit!(FileVisitLimit, limits::SEARCH_FILES);
bounded_limit!(DirectoryVisitLimit, limits::SEARCH_DIRECTORIES);

#[derive(Default)]
struct FileCount(usize);
#[derive(Default)]
struct DirectoryCount(usize);
#[derive(Default)]
struct EntryCount(usize);
#[derive(Default)]
struct ResultBytes(usize);

/// Untrusted wire/configuration boundary, converted once on the I/O worker.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FindFilesInput {
    /// Trusted editor workspace, never a model tool argument.
    pub root: PathBuf,
    /// Root-relative target, or an absolute path strictly within root.
    pub path: Option<PathBuf>,
    /// Non-empty glob; a basename pattern also matches nested files.
    pub pattern: String,
    /// Shared editor policy: exact directory basenames excluded at every depth.
    pub skip_directories: Vec<String>,
    /// Maximum regular files inspected, not maximum matches.
    pub max_files: usize,
    /// Separate directory traversal budget.
    pub max_directories: usize,
}

/// Captured, validated discovery operation. Not clonable execution authority.
pub struct FindFilesPlan {
    workspace: Workspace,
    target: PathBuf,
    pattern: String,
    matcher: GlobMatcher,
    skip_directories: Vec<String>,
    files: FileVisitLimit,
    directories: DirectoryVisitLimit,
}

impl TryFrom<FindFilesInput> for FindFilesPlan {
    type Error = CoreError;
    fn try_from(input: FindFilesInput) -> Result<Self, CoreError> {
        let files = FileVisitLimit::try_from(input.max_files)?;
        let directories = DirectoryVisitLimit::try_from(input.max_directories)?;
        let valid_path = |path: &Path| {
            path.as_os_str().len() <= limits::SEARCH_PATH_BYTES
                && !path
                    .components()
                    .any(|part| matches!(part, Component::ParentDir))
        };
        if !input.root.is_absolute()
            || !valid_path(&input.root)
            || input.path.as_ref().is_some_and(|p| !valid_path(p))
            || input.pattern.trim().is_empty()
            || input.pattern.len() > limits::SEARCH_PATTERN_BYTES
            || input.skip_directories.len() > 64
            || input.skip_directories.iter().any(|name| {
                name.is_empty()
                    || name.len() > 256
                    || name == "."
                    || name == ".."
                    || name.contains(['/', '\0'])
            })
        {
            return Err(CoreError::InvalidValue {
                field: "FindFilesInput",
            });
        }
        // Reject lexical escapes before filesystem access, then canonical escapes.
        let workspace = Workspace::try_from(input.root)?;
        let path = input.path.unwrap_or_default();
        let target = if path.is_absolute() {
            path
        } else {
            workspace.path().join(path)
        };
        let target = target.canonicalize()?;
        if !target.starts_with(workspace.path()) {
            return Err(CoreError::Rejected);
        }
        let normalized = if input.pattern.contains('/') {
            input.pattern.clone()
        } else {
            format!("**/{}", input.pattern)
        };
        let matcher = GlobBuilder::new(&normalized)
            .literal_separator(true)
            .build()
            .map_err(|_| CoreError::InvalidValue {
                field: "SearchGlob",
            })?
            .compile_matcher();
        Ok(Self {
            workspace,
            target,
            pattern: input.pattern,
            matcher,
            skip_directories: input.skip_directories,
            files,
            directories,
        })
    }
}

/// Completed domain result; rendering belongs to Rust, not the editor adapter.
#[derive(Serialize)]
pub struct FindFilesResult {
    /// Project-relative file paths, sorted for stable presentation.
    pub files: Vec<String>,
    /// Human-readable tool result with explicit incomplete-search notice.
    pub text: String,
    /// A visit, output, depth or result limit prevented exhaustive discovery.
    pub truncated: bool,
}

struct Walk {
    files: Vec<String>,
    visited_files: FileCount,
    directories: DirectoryCount,
    entries: EntryCount,
    bytes: ResultBytes,
    truncated: bool,
}

impl FindFilesPlan {
    /// Perform local filesystem work on a blocking worker, never on the actor.
    /// Cancellation is cooperative between OS calls; blocked filesystem syscalls
    /// cannot safely be killed. The worker slot remains held until actual drain.
    pub fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<FindFilesResult, CoreError> {
        check_live(cancel, deadline)?;
        self.workspace.revalidate()?;
        if self.target.canonicalize()? != self.target {
            return Err(CoreError::WorkspaceChanged);
        }
        let mut walk = Walk {
            files: Vec::new(),
            visited_files: FileCount::default(),
            directories: DirectoryCount::default(),
            entries: EntryCount::default(),
            bytes: ResultBytes::default(),
            truncated: false,
        };
        let metadata = fs::symlink_metadata(&self.target)?;
        if metadata.is_file() {
            if self.files.0 == 0 {
                walk.truncated = true;
            } else {
                self.visit_file(&self.target, &mut walk)?;
            }
        } else if metadata.is_dir() {
            if self.directories.0 == 0 || self.files.0 == 0 {
                walk.truncated = true;
            } else {
                // Incremental iterators avoid collecting a huge directory in memory.
                let mut stack = vec![fs::read_dir(&self.target)?];
                walk.directories.0 = 1;
                while let Some(directory) = stack.last_mut() {
                    check_live(cancel, deadline)?;
                    if walk.entries.0 >= limits::SEARCH_ENTRIES {
                        walk.truncated = true;
                        break;
                    }
                    let Some(entry) = directory.next() else {
                        stack.pop();
                        continue;
                    };
                    let entry = entry?;
                    walk.entries.0 = walk.entries.0.saturating_add(1);
                    let kind = entry.file_type()?;
                    // Never follow discovered symlinks, even if they currently point inside.
                    // No content is read; changed paths are omitted after final canonical check.
                    if kind.is_symlink() {
                        continue;
                    }
                    let path = entry.path();
                    if kind.is_dir() {
                        if self
                            .skip_directories
                            .iter()
                            .any(|name| entry.file_name() == name.as_str())
                        {
                            continue;
                        }
                        if walk.directories.0 >= self.directories.0
                            || stack.len() >= limits::SEARCH_DEPTH
                        {
                            walk.truncated = true;
                            continue;
                        }
                        if !self.contained(&path) {
                            continue;
                        }
                        walk.directories.0 = walk.directories.0.saturating_add(1);
                        stack.push(fs::read_dir(path)?);
                    } else if kind.is_file() {
                        if walk.visited_files.0 >= self.files.0 {
                            walk.truncated = true;
                            break;
                        }
                        if self.visit_file(&path, &mut walk)? {
                            break;
                        }
                    }
                }
            }
        } else {
            return Err(CoreError::Rejected);
        }
        check_live(cancel, deadline)?;
        self.workspace.revalidate()?;
        walk.files.sort();
        let mut text = if walk.files.is_empty() {
            format!(
                "No files matching {}",
                serde_json::to_string(&self.pattern).map_err(|_| CoreError::InvalidValue {
                    field: "SearchGlob"
                })?
            )
        } else {
            format!("{}\n", walk.files.join("\n"))
        };
        if walk.truncated {
            text.push_str(
                "\n... (additional files may be omitted; narrow the search or raise visit limits)",
            );
        }
        Ok(FindFilesResult {
            files: walk.files,
            text,
            truncated: walk.truncated,
        })
    }

    fn contained(&self, path: &Path) -> bool {
        path.canonicalize()
            .is_ok_and(|real| real == path && real.starts_with(&self.target))
    }

    fn visit_file(&self, path: &Path, walk: &mut Walk) -> Result<bool, CoreError> {
        walk.visited_files.0 = walk.visited_files.0.saturating_add(1);
        if ignored_artifact(path) || !self.contained(path) {
            return Ok(false);
        }
        let relative = path
            .strip_prefix(self.workspace.path())
            .map_err(|_| CoreError::Rejected)?;
        let target_relative = path
            .strip_prefix(&self.target)
            .map_err(|_| CoreError::Rejected)?;
        if !self.matcher.is_match(relative)
            && !self.matcher.is_match(target_relative)
            && !path
                .file_name()
                .is_some_and(|name| self.matcher.is_match(Path::new(name)))
        {
            return Ok(false);
        }
        // JSON wire paths must be unambiguous UTF-8 records, not lossy OS names.
        let text = relative.to_str().ok_or(CoreError::InvalidValue {
            field: "SearchResultPath",
        })?;
        if text.contains(['\n', '\r']) {
            return Err(CoreError::InvalidValue {
                field: "SearchResultPath",
            });
        }
        let bytes = walk
            .bytes
            .0
            .checked_add(text.len())
            .and_then(|n| n.checked_add(1))
            .ok_or(CoreError::ArithmeticOverflow)?;
        if walk.files.len() >= limits::SEARCH_RESULTS || bytes > limits::SEARCH_RESULT_BYTES {
            walk.truncated = true;
            return Ok(true);
        }
        walk.bytes.0 = bytes;
        walk.files.push(text.to_owned());
        Ok(false)
    }
}

fn ignored_artifact(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|name| {
            name.starts_with(".#")
                || name.ends_with('~')
                || path
                    .extension()
                    .and_then(|n| n.to_str())
                    .is_some_and(|extension| {
                        matches!(
                            extension,
                            "elc" | "eln" | "o" | "so" | "pyc" | "class" | "rlib" | "rmeta"
                        )
                    })
        })
}

fn check_live(cancel: &CancellationToken, deadline: Instant) -> Result<(), CoreError> {
    if cancel.is_cancelled() {
        Err(CoreError::Cancelled)
    } else if Instant::now() >= deadline {
        Err(CoreError::Deadline)
    } else {
        Ok(())
    }
}
