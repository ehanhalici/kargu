//! Retain resolved audit history without deleting unresolved or locked evidence.
use super::{
    JournalDirectory, RecoveredJournal, recover_bytes,
    storage::{self, Directory},
};
use crate::{
    constants::limits, edit::types::EditorEditId, error::CoreError, security::file::checkpoint,
};
use nix::{
    fcntl::AtFlags,
    sys::stat::{FileStat, fstatat},
    unistd::geteuid,
};
use std::{path::PathBuf, time::Instant};
use tokio_util::sync::CancellationToken;

struct Candidate {
    name: PathBuf,
    id: EditorEditId,
    stat: FileStat,
}
pub(super) fn prune(
    directory: &Directory,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<(), CoreError> {
    checkpoint(cancel, deadline)?;
    directory.revalidate()?;
    let mut candidates = Vec::new();
    for (count, entry) in std::fs::read_dir(&directory.path)?.enumerate() {
        checkpoint(cancel, deadline)?;
        if count >= limits::SEARCH_ENTRIES {
            return Err(CoreError::Limit);
        }
        let name = entry?.file_name();
        let Some(stem) = name.to_str().and_then(|name| name.strip_suffix(".ndjson")) else {
            continue;
        };
        let Ok(id) = EditorEditId::try_from(stem.to_owned()) else {
            continue;
        };
        let name = PathBuf::from(name);
        let Ok(stat) = fstatat(&directory.held, &name, AtFlags::AT_SYMLINK_NOFOLLOW) else {
            continue;
        };
        if (stat.st_mode & nix::libc::S_IFMT) != nix::libc::S_IFREG
            || (stat.st_mode & 0o7777) != 0o600
            || stat.st_nlink != 1
            || stat.st_uid != geteuid().as_raw()
        {
            continue;
        }
        candidates.push(Candidate { name, id, stat });
    }
    if candidates.len() < limits::EDIT_JOURNAL_FILES.min(limits::EDIT_JOURNAL_UNRESOLVED_FILES) {
        return Ok(());
    }
    candidates.sort_by(|left, right| {
        left.stat
            .st_mtime
            .cmp(&right.stat.st_mtime)
            .then_with(|| left.stat.st_mtime_nsec.cmp(&right.stat.st_mtime_nsec))
            .then_with(|| left.name.cmp(&right.name))
    });
    let mut resolved = Vec::new();
    let mut unresolved = 0usize;
    for candidate in candidates {
        checkpoint(cancel, deadline)?;
        let read = storage::read_locked(
            JournalDirectory(directory.path.clone()),
            &candidate.id,
            cancel,
            deadline,
        );
        let read = match read {
            Err(error @ (CoreError::Cancelled | CoreError::Deadline)) => return Err(error),
            other => other,
        };
        if let Ok(read) = read
            && read.matches(&candidate.stat)?
            && matches!(
                recover_bytes(&read.bytes, candidate.id.clone(), cancel, deadline)?,
                RecoveredJournal::Resolved { .. }
            )
        {
            resolved.push(candidate);
        } else {
            unresolved = unresolved.checked_add(1).ok_or(CoreError::Limit)?;
        }
    }
    // Unknown records are never sacrificed to make room for new effects.
    if unresolved >= limits::EDIT_JOURNAL_UNRESOLVED_FILES {
        return Err(CoreError::Limit);
    }
    let remove = resolved
        .len()
        .saturating_add(1)
        .saturating_sub(limits::EDIT_JOURNAL_FILES);
    for candidate in resolved.into_iter().take(remove) {
        checkpoint(cancel, deadline)?;
        let read = match storage::read_locked(
            JournalDirectory(directory.path.clone()),
            &candidate.id,
            cancel,
            deadline,
        ) {
            Ok(read) => read,
            Err(error @ (CoreError::Cancelled | CoreError::Deadline)) => return Err(error),
            Err(_) => continue,
        };
        if read.matches(&candidate.stat)?
            && matches!(
                recover_bytes(&read.bytes, candidate.id, cancel, deadline)?,
                RecoveredJournal::Resolved { .. }
            )
        {
            directory.revalidate()?;
            match read.remove(cancel, deadline) {
                Ok(()) => {}
                Err(CoreError::WorkspaceChanged) => {}
                Err(CoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
    }
    directory.revalidate()?;
    Ok(())
}
