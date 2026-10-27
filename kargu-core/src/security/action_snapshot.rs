//! Bounded filesystem evidence attached to an explicitly approved Git action.

use super::{ReadTarget, file::checkpoint};
use crate::{constants::limits, error::CoreError};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

pub(crate) struct ActionSnapshot {
    entries: BTreeMap<PathBuf, Entry>,
    digest: [u8; 32],
}
enum Entry {
    Missing,
    Present(ReadTarget),
    Symlink {
        metadata: fs::Metadata,
        destination: PathBuf,
    },
}
impl ActionSnapshot {
    pub(crate) fn capture(
        roots: Vec<PathBuf>,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Self, CoreError> {
        let mut entries = BTreeMap::new();
        for root in &roots {
            capture(root, &mut entries, cancel, deadline)?;
        }
        let mut hash = Sha256::new();
        for (path, entry) in &entries {
            let bytes = path.as_os_str().as_bytes();
            hash.update(
                u64::try_from(bytes.len())
                    .map_err(|_| CoreError::Limit)?
                    .to_le_bytes(),
            );
            hash.update(bytes);
            match entry {
                Entry::Missing => hash.update([0]),
                Entry::Symlink {
                    metadata,
                    destination,
                } => {
                    hash.update([2]);
                    hash_metadata(&mut hash, metadata);
                    hash.update(destination.as_os_str().as_bytes());
                }
                Entry::Present(target) => {
                    let meta = target.metadata()?;
                    hash.update([1]);
                    hash_metadata(&mut hash, &meta);
                }
            }
        }
        Ok(Self {
            entries,
            digest: hash.finalize().into(),
        })
    }
    pub(crate) fn digest(&self) -> &[u8; 32] {
        &self.digest
    }
    pub(crate) fn revalidate(&self) -> Result<(), CoreError> {
        for (path, entry) in &self.entries {
            match entry {
                Entry::Missing
                    if fs::symlink_metadata(path)
                        .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
                Entry::Missing => return Err(CoreError::WorkspaceChanged),
                Entry::Present(target) => target.revalidate()?,
                Entry::Symlink {
                    metadata,
                    destination,
                } => {
                    let current =
                        fs::symlink_metadata(path).map_err(|_| CoreError::WorkspaceChanged)?;
                    if super::file::Revision::from(current)
                        != super::file::Revision::from(metadata.clone())
                        || fs::read_link(path).map_err(|_| CoreError::WorkspaceChanged)?
                            != *destination
                    {
                        return Err(CoreError::WorkspaceChanged);
                    }
                }
            }
        }
        // Directory revisions include child insertions/removals. This is evidence
        // checked before spawn, not a filesystem lock or an atomic Git transaction.
        Ok(())
    }
}
fn hash_metadata(hash: &mut Sha256, meta: &fs::Metadata) {
    use std::os::unix::fs::MetadataExt;
    for n in [meta.dev(), meta.ino(), meta.len(), u64::from(meta.mode())] {
        hash.update(n.to_le_bytes());
    }
    for n in [
        meta.mtime(),
        meta.mtime_nsec(),
        meta.ctime(),
        meta.ctime_nsec(),
    ] {
        hash.update(n.to_le_bytes());
    }
}
fn capture(
    path: &Path,
    entries: &mut BTreeMap<PathBuf, Entry>,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<(), CoreError> {
    let mut pending = vec![(path.to_owned(), 0usize)];
    while let Some((path, depth)) = pending.pop() {
        checkpoint(cancel, deadline)?;
        if entries.len() >= limits::GIT_ACTION_ENTRIES || depth > limits::SEARCH_DEPTH {
            return Err(CoreError::Limit);
        }
        let metadata = match fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() => {
                // Git stages the link itself. Capture its bytes and lstat revision;
                // never traverse its destination or open a special-file target.
                let destination = fs::read_link(&path)?;
                if destination.as_os_str().len() > limits::SEARCH_PATH_BYTES {
                    return Err(CoreError::Limit);
                }
                if super::file::Revision::from(fs::symlink_metadata(&path)?)
                    != super::file::Revision::from(meta.clone())
                {
                    return Err(CoreError::WorkspaceChanged);
                }
                entries.insert(
                    path,
                    Entry::Symlink {
                        metadata: meta,
                        destination,
                    },
                );
                continue;
            }
            Ok(meta) if meta.is_file() || meta.is_dir() => meta,
            Ok(_) => return Err(CoreError::Rejected),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                entries.insert(path, Entry::Missing);
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        if path.canonicalize()? != path {
            return Err(CoreError::Rejected);
        }
        let target = ReadTarget::snapshot(path.clone())?;
        if metadata.is_dir() {
            for child in fs::read_dir(&path)? {
                checkpoint(cancel, deadline)?;
                if pending.len().saturating_add(entries.len()) >= limits::GIT_ACTION_ENTRIES {
                    return Err(CoreError::Limit);
                }
                pending.push((child?.path(), depth.saturating_add(1)));
            }
        }
        target.revalidate()?;
        entries.insert(path, Entry::Present(target));
    }
    Ok(())
}
