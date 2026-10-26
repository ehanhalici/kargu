//! Linux fd-rooted regular-file capture. No unsafe, special-file open or raw logs.

use super::checkpoint;
use crate::{configuration::MAX_SOURCE_BYTES, error::CoreError};
use nix::fcntl::{OFlag, open, openat};
use nix::sys::stat::Mode;
use std::{
    fs::{File, Metadata},
    io::Read,
    os::{fd::AsRawFd, unix::fs::MetadataExt},
    path::{Component, Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[derive(PartialEq, Eq)]
struct FileRevision {
    device: u64,
    inode: u64,
    size: u64,
    mode: u32,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl From<Metadata> for FileRevision {
    fn from(value: Metadata) -> Self {
        Self {
            device: value.dev(),
            inode: value.ino(),
            size: value.len(),
            mode: value.mode(),
            modified: (value.mtime(), value.mtime_nsec()),
            changed: (value.ctime(), value.ctime_nsec()),
        }
    }
}

pub(super) struct CapturedFile {
    original: PathBuf,
    canonical: PathBuf,
    pinned: File,
    revision: FileRevision,
}
impl CapturedFile {
    pub(super) fn open(
        original: &Path,
        canonical: PathBuf,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Self, CoreError> {
        checkpoint(cancel, deadline)?;
        let initial = canonical.metadata()?;
        if !initial.is_file() {
            return Err(CoreError::Rejected);
        }
        if initial.len() > MAX_SOURCE_BYTES as u64 {
            return Err(CoreError::Limit);
        }
        let flags = OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC;
        let parent = canonical.parent().ok_or(CoreError::Rejected)?;
        let mut directory = open(Path::new("/"), flags | OFlag::O_DIRECTORY, Mode::empty())
            .map_err(std::io::Error::from)?;
        for part in parent.components() {
            checkpoint(cancel, deadline)?;
            match part {
                Component::RootDir => {}
                Component::Normal(name) => {
                    directory = openat(
                        &directory,
                        Path::new(name),
                        flags | OFlag::O_DIRECTORY,
                        Mode::empty(),
                    )
                    .map_err(|_| CoreError::ConfigurationChanged)?;
                }
                _ => return Err(CoreError::Rejected),
            }
        }
        let name = canonical.file_name().ok_or(CoreError::Rejected)?;
        checkpoint(cancel, deadline)?;
        let pinned = File::from(
            openat(&directory, Path::new(name), flags, Mode::empty())
                .map_err(|_| CoreError::ConfigurationChanged)?,
        );
        let metadata = pinned.metadata()?;
        if !metadata.is_file() {
            return Err(CoreError::ConfigurationChanged);
        }
        let revision = FileRevision::from(metadata);
        if FileRevision::from(initial) != revision {
            return Err(CoreError::ConfigurationChanged);
        }
        checkpoint(cancel, deadline)?;
        Ok(Self {
            original: original.to_owned(),
            canonical,
            pinned,
            revision,
        })
    }

    fn revalidate(&self, reader: &File) -> Result<(), CoreError> {
        let same = self
            .original
            .canonicalize()
            .map_err(|_| CoreError::ConfigurationChanged)?
            == self.canonical
            && FileRevision::from(
                self.canonical
                    .metadata()
                    .map_err(|_| CoreError::ConfigurationChanged)?,
            ) == self.revision
            && FileRevision::from(self.pinned.metadata()?) == self.revision
            && FileRevision::from(reader.metadata()?) == self.revision;
        if same {
            Ok(())
        } else {
            Err(CoreError::ConfigurationChanged)
        }
    }

    pub(super) fn read(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Zeroizing<Vec<u8>>, CoreError> {
        checkpoint(cancel, deadline)?;
        // Reopen the pinned regular inode, not its potentially replaced pathname.
        // Linux /proc is already a platform prerequisite of the native core.
        let fd_path = PathBuf::from(format!("/proc/self/fd/{}", self.pinned.as_raw_fd()));
        let mut reader = File::from(
            open(
                &fd_path,
                OFlag::O_RDONLY | OFlag::O_NONBLOCK | OFlag::O_CLOEXEC,
                Mode::empty(),
            )
            .map_err(std::io::Error::from)?,
        );
        self.revalidate(&reader)?;
        let mut output = Zeroizing::new(Vec::with_capacity(MAX_SOURCE_BYTES));
        let mut chunk = Zeroizing::new([0_u8; 4096]);
        loop {
            checkpoint(cancel, deadline)?;
            let count = match reader.read(chunk.as_mut()) {
                Ok(count) => count,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error.into()),
            };
            checkpoint(cancel, deadline)?;
            if count == 0 {
                break;
            }
            if output.len().saturating_add(count) > MAX_SOURCE_BYTES {
                return Err(CoreError::Limit);
            }
            output.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
        }
        self.revalidate(&reader)?;
        checkpoint(cancel, deadline)?;
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    #[test]
    fn changed_inode_symlink_and_in_place_revision_cannot_be_read() -> TestResult {
        for change in [0, 1, 2] {
            let root = tempfile::tempdir()?;
            let path = root.path().join("config");
            std::fs::write(&path, "provider='original'")?;
            let held = CapturedFile::open(
                &path,
                path.canonicalize()?,
                &CancellationToken::new(),
                Instant::now() + std::time::Duration::from_secs(1),
            )?;
            if change == 0 {
                std::fs::rename(&path, root.path().join("old"))?;
                std::fs::write(&path, "provider='replacement'")?;
            } else if change == 1 {
                std::fs::rename(&path, root.path().join("old"))?;
                std::os::unix::fs::symlink(root.path().join("old"), &path)?;
            } else {
                std::fs::write(&path, "provider='changed-in-place'")?;
            }
            assert!(matches!(
                held.read(
                    &CancellationToken::new(),
                    Instant::now() + std::time::Duration::from_secs(1)
                ),
                Err(CoreError::ConfigurationChanged)
            ));
        }
        Ok(())
    }
}
