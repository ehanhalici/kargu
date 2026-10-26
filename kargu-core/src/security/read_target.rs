//! Pinned read-target identity, rechecked immediately before an adapter spawn.

use crate::error::CoreError;
use std::{fs::File, os::unix::fs::MetadataExt, path::PathBuf};

pub(crate) struct ReadTarget {
    pub(super) path: PathBuf,
    held: File,
    revision: Option<super::file::Revision>,
}
impl TryFrom<PathBuf> for ReadTarget {
    type Error = CoreError;
    fn try_from(path: PathBuf) -> Result<Self, CoreError> {
        let held = File::from(
            nix::fcntl::open(
                &path,
                nix::fcntl::OFlag::O_PATH
                    | nix::fcntl::OFlag::O_NOFOLLOW
                    | nix::fcntl::OFlag::O_CLOEXEC,
                nix::sys::stat::Mode::empty(),
            )
            .map_err(std::io::Error::from)?,
        );
        let metadata = held.metadata()?;
        if !(metadata.is_file() || metadata.is_dir()) {
            return Err(CoreError::Rejected);
        }
        Ok(Self {
            path,
            held,
            revision: None,
        })
    }
}
impl ReadTarget {
    pub(crate) fn snapshot(path: PathBuf) -> Result<Self, CoreError> {
        let mut target = Self::try_from(path)?;
        target.revision = Some(super::file::Revision::from(target.held.metadata()?));
        Ok(target)
    }
    pub(crate) fn duplicate(&self) -> Result<Self, CoreError> {
        Ok(Self {
            path: self.path.clone(),
            held: self.held.try_clone()?,
            revision: self.revision.clone(),
        })
    }
    pub(super) fn immutable(&self) -> bool {
        self.revision.is_some()
    }
    pub(crate) fn revalidate(&self) -> Result<(), CoreError> {
        let held = self.held.metadata()?;
        let current = self
            .path
            .metadata()
            .map_err(|_| CoreError::WorkspaceChanged)?;
        if self.revision.as_ref().is_some_and(|revision| {
            *revision != super::file::Revision::from(held.clone())
                || *revision != super::file::Revision::from(current.clone())
        }) {
            return Err(CoreError::WorkspaceChanged);
        }
        if held.dev() != current.dev()
            || held.ino() != current.ino()
            || self
                .path
                .canonicalize()
                .map_err(|_| CoreError::WorkspaceChanged)?
                != self.path
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
    pub(super) fn metadata(&self) -> Result<std::fs::Metadata, CoreError> {
        Ok(self.held.metadata()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn immutable_file_evidence_is_not_refreshed_by_duplicate_or_in_place_write()
    -> Result<(), Box<dyn std::error::Error>> {
        let root = tempfile::tempdir()?;
        let file = root.path().join("config");
        std::fs::write(&file, "before")?;
        let original = ReadTarget::snapshot(file.clone())?;
        let duplicate = original.duplicate()?;
        original.revalidate()?;
        duplicate.revalidate()?;
        std::fs::write(&file, "after with a different revision")?;
        assert!(matches!(
            original.revalidate(),
            Err(CoreError::WorkspaceChanged)
        ));
        assert!(matches!(
            duplicate.revalidate(),
            Err(CoreError::WorkspaceChanged)
        ));
        Ok(())
    }

    #[test]
    fn replaced_file_or_directory_cannot_borrow_the_captured_target_identity()
    -> Result<(), Box<dyn std::error::Error>> {
        let root = tempfile::tempdir()?;
        let file = root.path().join("file");
        std::fs::write(&file, "before")?;
        let captured = ReadTarget::try_from(file.clone())?;
        // This is a live read, not approval of an immutable content snapshot.
        std::fs::write(&file, "new content in the same file")?;
        captured.revalidate()?;
        std::fs::rename(&file, root.path().join("old-file"))?;
        std::os::unix::fs::symlink(root.path().join("old-file"), &file)?;
        assert!(matches!(
            captured.revalidate(),
            Err(CoreError::WorkspaceChanged)
        ));
        let directory = root.path().join("directory");
        std::fs::create_dir(&directory)?;
        let captured = ReadTarget::try_from(directory.clone())?;
        std::fs::rename(&directory, root.path().join("old-directory"))?;
        std::fs::create_dir(&directory)?;
        assert!(matches!(
            captured.revalidate(),
            Err(CoreError::WorkspaceChanged)
        ));
        Ok(())
    }
}
