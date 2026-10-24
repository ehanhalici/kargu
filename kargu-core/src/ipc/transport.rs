use super::{
    CONTROL_BYTES, CONTROL_CAPACITY, MAX_FRAME_BYTES,
    pending::PendingRequests,
    protocol::{self, Message},
};
use crate::constants::{protocol::methods, timeouts};
use crate::domain::{ByteLimit, RequestScope};
use crate::host::Host;
use bytes::BytesMut;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::{io, sync::Arc};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};
use tokio_util::codec::{Decoder, FramedRead, FramedWrite, LinesCodec};
use tokio_util::task::AbortOnDropHandle;

/// Errors are deliberately payload-free so callers can safely classify them.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("framing or IO error")]
    Framing,
    #[error("outbound queue or frame limit reached")]
    Overloaded,
    #[error("writer failed or timed out")]
    Writer,
}

struct Frame {
    line: String,
    _permit: OwnedSemaphorePermit,
}

// Unlike LinesCodec's default EOF behavior, an incomplete trailing line is
// never accepted as a successful frame.
struct StrictLines {
    lines: LinesCodec,
}
impl StrictLines {
    fn new(limit: ByteLimit) -> Self {
        Self {
            lines: LinesCodec::new_with_max_length(limit.as_usize()),
        }
    }
}
impl Decoder for StrictLines {
    type Item = String;
    type Error = io::Error;
    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<String>, io::Error> {
        self.lines
            .decode(src)
            .map_err(|_| io::Error::other("invalid frame"))
    }
    fn decode_eof(&mut self, src: &mut BytesMut) -> Result<Option<String>, io::Error> {
        if let Some(line) = self.decode(src)? {
            return Ok(Some(line));
        }
        if src.is_empty() {
            Ok(None)
        } else {
            Err(io::Error::other("truncated frame"))
        }
    }
}

/// Serve one owned connection; EOF and writer failure revoke all pending work.
/// Only lifecycle capabilities are advertised during this migration stage.
pub async fn serve<R, W>(reader: R, writer: W) -> Result<(), TransportError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (tx, mut rx) = mpsc::channel::<Frame>(CONTROL_CAPACITY);
    let permits = Arc::new(Semaphore::new(CONTROL_BYTES));
    let mut writer_task = AbortOnDropHandle::new(tokio::spawn(async move {
        let mut sink = FramedWrite::new(writer, LinesCodec::new_with_max_length(MAX_FRAME_BYTES));
        while let Some(frame) = rx.recv().await {
            tokio::time::timeout(timeouts::WRITE, sink.send(frame.line))
                .await
                .map_err(|_| TransportError::Writer)?
                .map_err(|_| TransportError::Writer)?;
        }
        Ok::<(), TransportError>(())
    }));
    let mut pending = PendingRequests::default();
    let mut writer_finished = false;
    let result = tokio::select! {
        result = read_loop(reader, &tx, permits, &mut pending) => result,
        result = &mut writer_task => {
            writer_finished = true;
            result.map_err(|_| TransportError::Writer).and_then(|result| result)
        }
    };
    pending.disconnect();
    drop(tx);
    if !writer_finished {
        match tokio::time::timeout(timeouts::WRITE, &mut writer_task).await {
            Ok(Ok(Ok(()))) => {}
            Ok(_) => return Err(TransportError::Writer),
            Err(_) => {
                writer_task.abort();
                let _ = writer_task.await;
                return Err(TransportError::Writer);
            }
        }
    }
    result
}

async fn read_loop<R: AsyncRead + Unpin>(
    reader: R,
    tx: &mpsc::Sender<Frame>,
    permits: Arc<Semaphore>,
    pending: &mut PendingRequests,
) -> Result<(), TransportError> {
    let mut input = FramedRead::new(reader, StrictLines::new(ByteLimit::WIRE_MAX));
    let mut host = Host::new();
    let mut expiry = tokio::time::interval(timeouts::PENDING_SWEEP);
    loop {
        let frame = tokio::select! {
            frame = input.next() => frame,
            _ = expiry.tick() => { pending.expire(tokio::time::Instant::now()); continue; }
        };
        let Some(frame) = frame else {
            return Ok(());
        };
        let line = frame.map_err(|_| TransportError::Framing)?;
        let reply = match protocol::decode(&line) {
            Err(fault) => Some(fault.response(None)),
            Ok(Message::Response { id, outcome }) => {
                pending.resolve(&id, outcome);
                None
            }
            Ok(Message::Call { id, method, params }) => {
                if method == methods::CANCEL && id.is_none() {
                    if let (Some(id), Some(scope)) = (
                        params.get("request_id").and_then(protocol::RpcId::parse),
                        params
                            .get("scope")
                            .and_then(Value::as_str)
                            .and_then(|s| RequestScope::try_from(s.to_owned()).ok()),
                    ) {
                        pending.cancel(&id, &scope);
                    }
                    continue;
                }
                let dispatch = host.dispatch(&method, params, id.is_some());
                if dispatch.exit {
                    return Ok(());
                }
                input.decoder_mut().lines =
                    LinesCodec::new_with_max_length(host.frame_limit().as_usize());
                if host.is_shutdown() {
                    pending.disconnect();
                }
                id.as_ref().map(|id| match dispatch.result {
                    Ok(result) => protocol::success(id, result),
                    Err(fault) => fault.response(Some(id)),
                })
            }
        };
        if let Some(reply) = reply {
            let line = serde_json::to_string(&reply).map_err(|_| TransportError::Framing)?;
            if line.len() > host.frame_limit().as_usize() {
                return Err(TransportError::Overloaded);
            }
            let bytes = u32::try_from(line.len() + 1).map_err(|_| TransportError::Overloaded)?;
            let permit = permits
                .clone()
                .try_acquire_many_owned(bytes)
                .map_err(|_| TransportError::Overloaded)?;
            tx.try_send(Frame {
                line,
                _permit: permit,
            })
            .map_err(|_| TransportError::Overloaded)?;
        }
    }
}
