//! Complete-record prefix accounting and bounded observations, not matching logic.

use super::Archive;
use crate::{
    application::RunHandle,
    domain::{CaptureStop, OutputRecords, RecordLimit},
    error::CoreError,
};
use tokio::sync::watch;

pub(super) struct RecordCapture {
    limit: RecordLimit,
    seen: Option<OutputRecords>,
    event: watch::Sender<Option<CaptureStop>>,
}
impl RecordCapture {
    pub fn push(
        &mut self,
        archive: &mut Archive,
        bytes: &[u8],
        run: &RunHandle,
    ) -> Result<(), CoreError> {
        let Some(mut count) = self.seen else {
            return archive.discard(bytes.len());
        };
        let mut end = None;
        for (index, byte) in bytes.iter().enumerate() {
            if *byte == b'\n' {
                count = count.next()?;
                if self.limit.reached(count) {
                    end = Some(index.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?);
                    break;
                }
            }
        }
        self.seen = Some(count);
        let accepted = end.unwrap_or(bytes.len());
        archive.push(bytes.get(..accepted).ok_or(CoreError::CleanupFailed)?, run)?;
        let stopped = if archive.truncated() {
            Some(CaptureStop::Bytes)
        } else {
            end.map(|_| CaptureStop::Records)
        };
        archive.discard(bytes.len().saturating_sub(accepted))?;
        if let Some(reason) = stopped {
            self.seen = None;
            self.event.send_replace(Some(reason));
        }
        Ok(())
    }
}

pub(super) struct RecordMonitor(Option<watch::Receiver<Option<CaptureStop>>>);
impl RecordMonitor {
    pub fn new(limit: Option<RecordLimit>) -> (Option<RecordCapture>, Self) {
        match limit {
            Some(limit) => {
                let (tx, rx) = watch::channel(None);
                (
                    Some(RecordCapture {
                        limit,
                        seen: Some(OutputRecords::ZERO),
                        event: tx,
                    }),
                    Self(Some(rx)),
                )
            }
            None => (None, Self(None)),
        }
    }
    pub fn current(&self) -> Option<CaptureStop> {
        self.0.as_ref().and_then(|rx| *rx.borrow())
    }
    pub async fn reached(&mut self) -> CaptureStop {
        let Some(receiver) = &mut self.0 else {
            return std::future::pending().await;
        };
        loop {
            let observed = *receiver.borrow_and_update();
            if let Some(reason) = observed {
                return reason;
            }
            if receiver.changed().await.is_err() {
                return std::future::pending().await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        application::{ApplicationActor, Mode, RunSettings},
        domain::{
            ApplicationId, ByteOffset, ConfigRevision, OutputLimit, OutputRetention,
            PolicyRevision, ToolCallLimit,
        },
        security::Workspace,
    };
    use std::time::Duration;

    #[test]
    fn fragmented_records_freeze_exact_utf8_prefix_and_keep_raw_cursor()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let run = actor.admit(
            &session,
            RunSettings::new(
                Mode::Agent,
                Workspace::try_from(directory.path().to_path_buf())?,
                ToolCallLimit::default(),
                Duration::from_secs(5),
                ConfigRevision::try_from(1)?,
                PolicyRevision::try_from(1)?,
            )?,
        )?;
        let (capture, monitor) = RecordMonitor::new(Some(RecordLimit::try_from(2)?));
        let mut capture = capture.ok_or(CoreError::CleanupFailed)?;
        let mut archive = Archive::new(OutputRetention::Prefix, OutputLimit::try_from(64_usize)?);
        let chunks: &[&[u8]] = &[b"first\n\xc3", b"\xbc", b"\nthird\n", b"fourth\n"];
        for chunk in chunks {
            capture.push(&mut archive, chunk, &run)?;
        }
        let page = archive.page(ByteOffset::ZERO)?;
        assert_eq!(page.bytes, "first\nü\n".as_bytes());
        assert_eq!(page.next_cursor.as_u64(), 22);
        assert!(page.truncated);
        assert_eq!(monitor.current(), Some(CaptureStop::Records));
        actor.finish(&run)?;
        Ok(())
    }

    #[tokio::test]
    async fn closed_stdout_without_a_budget_event_does_not_stop_the_supervisor()
    -> Result<(), Box<dyn std::error::Error>> {
        let (capture, mut monitor) = RecordMonitor::new(Some(RecordLimit::try_from(1)?));
        drop(capture);
        assert_eq!(monitor.current(), None);
        assert!(
            tokio::time::timeout(Duration::from_millis(10), monitor.reached())
                .await
                .is_err()
        );
        Ok(())
    }
}
