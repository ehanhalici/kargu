//! Pinned regular-file reader; revision checks surround bounded, cooperative I/O.

use crate::error::CoreError;
use nix::{
    fcntl::{OFlag, open, openat},
    sys::stat::Mode,
};
use std::{
    fs::{File, Metadata},
    io::Read,
    os::{fd::AsRawFd, unix::fs::MetadataExt},
    path::{Component, Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Revision {
    device: u64,
    inode: u64,
    size: u64,
    mode: u32,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl From<Metadata> for Revision {
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

pub(crate) fn checkpoint(cancel: &CancellationToken, deadline: Instant) -> Result<(), CoreError> {
    if cancel.is_cancelled() {
        Err(CoreError::Cancelled)
    } else if Instant::now() >= deadline {
        Err(CoreError::Deadline)
    } else {
        Ok(())
    }
}

pub(crate) struct PinnedFile {
    original: PathBuf,
    canonical: PathBuf,
    held: File,
    revision: Revision,
}
pub(crate) struct PinnedReader {
    snapshot: PinnedFile,
    reader: File,
}
impl PinnedFile {
    pub(crate) fn open(
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
        let flags = OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC;
        let parent = canonical.parent().ok_or(CoreError::Rejected)?;
        let mut directory = open(Path::new("/"), flags | OFlag::O_DIRECTORY, Mode::empty())
            .map_err(std::io::Error::from)?;
        for component in parent.components() {
            checkpoint(cancel, deadline)?;
            match component {
                Component::RootDir => {}
                Component::Normal(name) => {
                    directory = openat(
                        &directory,
                        Path::new(name),
                        flags | OFlag::O_DIRECTORY,
                        Mode::empty(),
                    )
                    .map_err(|_| CoreError::WorkspaceChanged)?;
                }
                _ => return Err(CoreError::Rejected),
            }
        }
        let name = canonical.file_name().ok_or(CoreError::Rejected)?;
        let held = File::from(
            openat(&directory, Path::new(name), flags, Mode::empty())
                .map_err(|_| CoreError::WorkspaceChanged)?,
        );
        let revision = Revision::from(held.metadata()?);
        if Revision::from(initial) != revision {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(Self {
            original: original.to_owned(),
            canonical,
            held,
            revision,
        })
    }
    pub(crate) fn size(&self) -> u64 {
        self.revision.size
    }
    pub(crate) fn reader(self) -> Result<PinnedReader, CoreError> {
        let path = PathBuf::from(format!("/proc/self/fd/{}", self.held.as_raw_fd()));
        let reader = File::from(
            open(
                &path,
                OFlag::O_RDONLY | OFlag::O_NONBLOCK | OFlag::O_CLOEXEC,
                Mode::empty(),
            )
            .map_err(std::io::Error::from)?,
        );
        self.revalidate(&reader)?;
        Ok(PinnedReader {
            snapshot: self,
            reader,
        })
    }
    fn revalidate(&self, reader: &File) -> Result<(), CoreError> {
        if self
            .original
            .canonicalize()
            .map_err(|_| CoreError::WorkspaceChanged)?
            != self.canonical
            || Revision::from(
                self.canonical
                    .metadata()
                    .map_err(|_| CoreError::WorkspaceChanged)?,
            ) != self.revision
            || Revision::from(self.held.metadata()?) != self.revision
            || Revision::from(reader.metadata()?) != self.revision
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
}
impl PinnedReader {
    pub(crate) fn read(
        &mut self,
        buffer: &mut [u8],
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<usize, CoreError> {
        loop {
            checkpoint(cancel, deadline)?;
            match self.reader.read(buffer) {
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                result => {
                    checkpoint(cancel, deadline)?;
                    return Ok(result?);
                }
            }
        }
    }
    pub(crate) fn finish(self) -> Result<(), CoreError> {
        self.snapshot.revalidate(&self.reader)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replaced_paths_and_in_place_writes_invalidate_pinned_reader()
    -> Result<(), Box<dyn std::error::Error>> {
        for replacement in [false, true] {
            let root = tempfile::tempdir()?;
            let path = root.path().join("source");
            std::fs::write(&path, "before")?;
            let mut reader = PinnedFile::open(
                &path,
                path.canonicalize()?,
                &CancellationToken::new(),
                Instant::now() + std::time::Duration::from_secs(1),
            )?
            .reader()?;
            let mut bytes = [0; 32];
            reader.read(
                &mut bytes,
                &CancellationToken::new(),
                Instant::now() + std::time::Duration::from_secs(1),
            )?;
            if replacement {
                std::fs::rename(&path, root.path().join("old"))?;
            }
            std::fs::write(&path, "changed")?;
            assert!(matches!(reader.finish(), Err(CoreError::WorkspaceChanged)));
        }
        Ok(())
    }
}
