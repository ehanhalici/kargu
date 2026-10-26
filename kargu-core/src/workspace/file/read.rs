//! Owned disk capture; no actor writes or editor callbacks on the I/O worker.

use super::{FileExcerpt, ReadFileInput, Snapshot, Source, decode, render};
use crate::{
    error::CoreError,
    security::{
        Workspace,
        file::{PinnedFile, checkpoint},
    },
};
use std::time::Instant;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

struct ProbedChars(usize);
struct ReadBytes(usize);

impl ReadFileInput {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<FileExcerpt, CoreError> {
        checkpoint(cancel, deadline)?;
        let (snapshot, bytes_read) = match self.source {
            Source::Editor {
                text,
                from_available,
                complete,
                ..
            } => (
                Snapshot {
                    text: Zeroizing::new(text),
                    available: from_available,
                    complete,
                },
                0,
            ),
            Source::Disk { root, path } => {
                let workspace = Workspace::try_from(root.0)?;
                let original = workspace.path().join(path.0);
                if !original.starts_with(workspace.path()) {
                    return Err(CoreError::Rejected);
                }
                let canonical = original.canonicalize()?;
                if !canonical.starts_with(workspace.path()) {
                    return Err(CoreError::Rejected);
                }
                let file = PinnedFile::open(&original, canonical, cancel, deadline)?;
                let size = file.size();
                let mut reader = file.reader()?;
                let mut decoder = decode::Decoder::default();
                let mut scan =
                    render::Scanner::new(&self.window, &self.scan_chars, &self.output_chars);
                let mut bytes = Zeroizing::new([0u8; 4096]);
                let mut consumed = ReadBytes(0);
                let mut probed = ProbedChars(0);
                while consumed.0 < self.max_bytes.0 && (!scan.finished() || probed.0 < 1000) {
                    let capacity = bytes.len().min(self.max_bytes.0.saturating_sub(consumed.0));
                    let chunk = bytes.get_mut(..capacity).ok_or(CoreError::Limit)?;
                    let count = reader.read(chunk, cancel, deadline)?;
                    consumed.0 = consumed.0.saturating_add(count);
                    let complete = count == 0
                        || u64::try_from(consumed.0).map_err(|_| CoreError::Limit)? >= size;
                    let text =
                        decoder.decode(chunk.get(..count).ok_or(CoreError::Limit)?, complete)?;
                    for character in text.chars().take(1000usize.saturating_sub(probed.0)) {
                        if character == '\0' {
                            return Err(CoreError::InvalidValue {
                                field: "BinaryFile",
                            });
                        }
                        probed.0 = probed.0.saturating_add(1);
                    }
                    scan.ingest(&text, complete, cancel, deadline)?;
                    if complete {
                        break;
                    }
                }
                reader.finish()?;
                workspace.revalidate()?;
                (scan.into_snapshot(), consumed.0)
            }
        };
        checkpoint(cancel, deadline)?;
        render::excerpt(
            &self.display_path.0,
            &self.window,
            &self.output_chars,
            snapshot,
            bytes_read,
        )
    }
}
