//! Configuration-sized facade over the shared fd-rooted regular-file reader.

use crate::{
    configuration::MAX_SOURCE_BYTES,
    error::CoreError,
    security::file::{PinnedFile, checkpoint},
};
use std::{
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

pub(super) struct CapturedFile(PinnedFile);
fn configuration_error(error: CoreError) -> CoreError {
    match error {
        CoreError::WorkspaceChanged => CoreError::ConfigurationChanged,
        other => other,
    }
}
impl CapturedFile {
    pub(super) fn open(
        original: &Path,
        canonical: PathBuf,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Self, CoreError> {
        let file =
            PinnedFile::open(original, canonical, cancel, deadline).map_err(configuration_error)?;
        if file.size() > MAX_SOURCE_BYTES as u64 {
            return Err(CoreError::Limit);
        }
        Ok(Self(file))
    }
    pub(super) fn read(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<Zeroizing<Vec<u8>>, CoreError> {
        let mut reader = self.0.reader().map_err(configuration_error)?;
        let mut output = Zeroizing::new(Vec::with_capacity(MAX_SOURCE_BYTES));
        let mut chunk = Zeroizing::new([0_u8; 4096]);
        loop {
            let count = reader.read(chunk.as_mut(), cancel, deadline)?;
            if count == 0 {
                break;
            }
            if output.len().saturating_add(count) > MAX_SOURCE_BYTES {
                return Err(CoreError::Limit);
            }
            output.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
        }
        reader.finish().map_err(configuration_error)?;
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
