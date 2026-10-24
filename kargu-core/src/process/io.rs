//! Process pipes and bounded input acknowledgements, not lifecycle authority.

use super::{Archive, InputMessage, activity::Activity, records::RecordCapture};
use crate::{application::RunHandle, constants::limits, error::CoreError};
use std::sync::Arc;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    process::ChildStdin,
    sync::{Mutex, mpsc},
};
use tokio_util::sync::CancellationToken;

pub(super) async fn drain<R: AsyncRead + Unpin>(
    mut pipe: R,
    archive: Arc<Mutex<Archive>>,
    run: RunHandle,
    activity: Activity,
    mut capture: Option<RecordCapture>,
) -> Result<(), CoreError> {
    let mut buffer = vec![0_u8; limits::PROCESS_PAGE_BYTES];
    loop {
        let count = pipe.read(&mut buffer).await?;
        if count == 0 {
            archive.lock().await.eof = true;
            return Ok(());
        }
        activity.record();
        let chunk = buffer.get(..count).ok_or(CoreError::CleanupFailed)?;
        let mut archive = archive.lock().await;
        match &mut capture {
            Some(capture) => capture.push(&mut archive, chunk, &run)?,
            None => archive.push(chunk, &run)?,
        }
    }
}

pub(super) async fn input_loop(
    mut pipe: ChildStdin,
    mut rx: mpsc::Receiver<InputMessage>,
    cancel: CancellationToken,
    activity: Activity,
) {
    loop {
        let command = tokio::select! { biased;
            _ = cancel.cancelled() => break,
            command = rx.recv() => match command {Some(command)=>command, None=>break},
        };
        match command {
            InputMessage::Write(chunk, ack) => {
                let result = tokio::select! { biased;
                    _ = cancel.cancelled() => Err(CoreError::Cancelled),
                    result = write_chunk(&mut pipe, &chunk.0, &activity) => result,
                };
                let failed = result.is_err();
                let _ = ack.send(result);
                if failed {
                    break;
                }
            }
            InputMessage::Eof(ack) => {
                drop(pipe);
                let _ = ack.send(Ok(()));
                break;
            }
        }
    }
}

async fn write_chunk<W: AsyncWrite + Unpin>(
    pipe: &mut W,
    mut remaining: &[u8],
    activity: &Activity,
) -> Result<(), CoreError> {
    while !remaining.is_empty() {
        let count = pipe.write(remaining).await?;
        if count == 0 {
            return Err(CoreError::Io(std::io::ErrorKind::WriteZero.into()));
        }
        activity.record();
        remaining = remaining.get(count..).ok_or(CoreError::CleanupFailed)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{domain::IdleTimeout, process::activity::IdleMonitor};
    use std::time::Duration;

    #[tokio::test(start_paused = true)]
    async fn partial_stdin_progress_resets_idle_before_the_whole_chunk_is_acked()
    -> Result<(), Box<dyn std::error::Error>> {
        let (mut writer, mut reader) = tokio::io::duplex(2);
        let (activity, mut idle) =
            IdleMonitor::new(IdleTimeout::try_from(Some(Duration::from_millis(50)))?);
        let writing = write_chunk(&mut writer, b"abcdef", &activity);
        let reading = async {
            let mut received = Vec::new();
            for _ in 0..3 {
                tokio::time::sleep(Duration::from_millis(40)).await;
                let mut chunk = [0_u8; 2];
                reader.read_exact(&mut chunk).await?;
                received.extend(chunk);
            }
            Ok::<_, CoreError>(received)
        };
        tokio::select! {
            result = async { tokio::try_join!(writing, reading) } => {
                let (_, received) = result?;
                assert_eq!(received, b"abcdef");
            },
            expired = idle.expired() => { expired?; return Err("active partial stdin was classified idle".into()); },
        }
        Ok(())
    }
}
