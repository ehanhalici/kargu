use super::{
    CONTROL_BYTES, CONTROL_CAPACITY, MAX_FRAME_BYTES,
    api::ApiRequests,
    execution::Commands,
    lifecycle::Lifecycle,
    pending::PendingRequests,
    protocol::{self, Message},
    read_tools::ReadTools,
};
use crate::application::host::Host;
use crate::constants::{protocol::methods, timeouts};
use crate::domain::{ByteLimit, RequestScope};
use bytes::BytesMut;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::{io, sync::Arc};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};
use tokio_util::codec::{Decoder, FramedRead, FramedWrite, LinesCodec};
use tokio_util::sync::CancellationToken;
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
    #[error("read worker failed during cleanup")]
    ReadWorker,
    /// Command owner or process cleanup failed.
    #[error("command service cleanup failed")]
    Command,
}

struct Frame {
    line: String,
    _permit: OwnedSemaphorePermit,
}

struct Services {
    reads: ReadTools,
    commands: Commands,
    api: ApiRequests,
    lifecycle: Lifecycle,
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
/// Preparation runs off-mailbox; exact approvals and job completions are polled.
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
    let stop = CancellationToken::new();
    let mut writer_finished = false;
    let result = {
        let reader_task = read_loop(reader, &tx, permits, &mut pending, &stop);
        tokio::pin!(reader_task);
        tokio::select! {
          result = &mut reader_task => result,
          result = &mut writer_task => {
              writer_finished = true;
              stop.cancel();
              let _ = (&mut reader_task).await;
              result.map_err(|_| TransportError::Writer).and_then(|result| result)
          }
        }
    };
    // The read future disconnects pending calls before draining subprocesses.
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
    stop: &CancellationToken,
) -> Result<(), TransportError> {
    let mut host = Host::new();
    let mut services = Services {
        reads: ReadTools::default(),
        commands: Commands::new().map_err(|_| TransportError::Command)?,
        api: ApiRequests::default(),
        lifecycle: Lifecycle::default(),
    };
    let result = read_messages(
        reader,
        tx,
        &permits,
        pending,
        &mut host,
        &mut services,
        stop,
    )
    .await;
    pending.disconnect();
    let Services {
        reads,
        commands,
        api,
        ..
    } = &mut services;
    reads.cancel_all();
    commands.cancel_all();
    api.drain().await.map_err(|_| TransportError::ReadWorker)?;
    while !commands.is_empty() {
        commands
            .tick(&mut host, pending)
            .map_err(|_| TransportError::Command)?;
        tokio::time::sleep(timeouts::PROCESS_POLL).await;
    }
    // EOF/error revokes publication immediately, but worker slots are not released
    // early. Blocking filesystem calls cannot be safely aborted by dropping a task.
    while let Some(completion) = reads.next(&host).await {
        completion
            .map_err(|_| TransportError::ReadWorker)?
            .publish(&mut host);
    }
    result
}

async fn read_messages<R: AsyncRead + Unpin>(
    reader: R,
    tx: &mpsc::Sender<Frame>,
    permits: &Arc<Semaphore>,
    pending: &mut PendingRequests,
    host: &mut Host,
    services: &mut Services,
    stop: &CancellationToken,
) -> Result<(), TransportError> {
    let Services {
        reads,
        commands,
        api,
        lifecycle,
    } = services;
    let mut input = FramedRead::new(reader, StrictLines::new(ByteLimit::WIRE_MAX));
    let mut expiry = tokio::time::interval(timeouts::PENDING_SWEEP);
    let mut shutdown_reply = None;
    loop {
        for reply in api.collect(host) {
            queue_reply(reply, host.frame_limit(), tx, permits)?;
        }
        for reply in lifecycle
            .collect(host, |application| {
                reads.owns_application(application)
                    || commands.owns_application(application)
                    || api.owns_application(application)
            })
            .map_err(|_| TransportError::Command)?
        {
            queue_reply(reply, host.frame_limit(), tx, permits)?;
        }
        if reads.is_empty()
            && commands.is_empty()
            && api.is_empty()
            && lifecycle.is_empty()
            && let Some(reply) = shutdown_reply.take()
        {
            queue_reply(reply, host.frame_limit(), tx, permits)?;
        }
        let frame = tokio::select! {
            _ = stop.cancelled() => return Ok(()),
            frame = input.next() => frame,
            completion = async {
                // Network producers backpressure on actual writer capacity. The
                // mailbox still accepts cancellation, owner-close and ping while
                // this future waits; no event is consumed without frame capacity.
                let bytes = u32::try_from(host.frame_limit().as_usize()).map_err(|_| TransportError::Overloaded)?;
                let permit = permits.clone().acquire_many_owned(bytes).await.map_err(|_| TransportError::Writer)?;
                drop(permit);
                api.next(host, pending).await.map_err(|_| TransportError::ReadWorker)
            }, if !api.is_empty() => {
                if let Some(reply) = completion? {
                    queue_reply(reply, host.frame_limit(), tx, permits)?;
                }
                if reads.is_empty() && commands.is_empty() && api.is_empty() && lifecycle.is_empty() && let Some(reply) = shutdown_reply.take() {
                    queue_reply(reply, host.frame_limit(), tx, permits)?;
                }
                continue;
            }
            completion = reads.next(host), if !reads.is_empty() => {
                let reply = completion.ok_or(TransportError::ReadWorker)?
                    .map_err(|_| TransportError::ReadWorker)?;
                let reply = reply.publish(host);
                queue_reply(reply, host.frame_limit(), tx, permits)?;
                if reads.is_empty() && commands.is_empty() && api.is_empty() && lifecycle.is_empty() && let Some(reply) = shutdown_reply.take() {
                    queue_reply(reply, host.frame_limit(), tx, permits)?;
                }
                continue;
            }
            _ = expiry.tick() => {
                pending.expire(tokio::time::Instant::now());
                host.sweep_configuration(std::time::Instant::now());
                reads.sweep(host);
                api.sweep(host);
                for message in commands.tick(host, pending).map_err(|_| TransportError::Command)? {
                    queue_reply(message, host.frame_limit(), tx, permits)?;
                }
                if reads.is_empty() && commands.is_empty() && api.is_empty() && lifecycle.is_empty() && let Some(reply) = shutdown_reply.take() {
                    queue_reply(reply, host.frame_limit(), tx, permits)?;
                }
                continue;
            }
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
                        if host.matches_epoch(&scope) {
                            reads.cancel(&id);
                            commands.cancel(&id);
                            api.cancel(&id);
                            lifecycle.cancel(&id);
                        }
                    }
                    continue;
                }
                if id.as_ref().is_some_and(|id| {
                    reads.contains(id)
                        || commands.contains(id)
                        || api.contains(id)
                        || lifecycle.contains(id)
                }) {
                    // Two responses with the same live id would be ambiguous.
                    return Err(TransportError::Framing);
                }
                if method == methods::APPLICATION_CLOSE {
                    if let Some(id) = id.as_ref()
                        && let Err(fault) = lifecycle.start(host, id.clone(), params)
                    {
                        queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                    }
                    reads.sweep(host);
                    api.sweep(host);
                    continue;
                }
                if method == methods::API_REQUEST {
                    if let Some(id) = id.as_ref()
                        && let Err(fault) = api.start(host, id.clone(), params)
                    {
                        queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::API_BUDGET_OPEN
                        | methods::API_BUDGET_CLOSE
                        | methods::API_BUDGET_SNAPSHOT
                ) {
                    if let Some(id) = id.as_ref() {
                        let reply = match api.budget_rpc(host, &method, id.clone(), params) {
                            Ok(Some(value)) => Some(protocol::success(id, value)),
                            Ok(None) => None,
                            Err(fault) => Some(fault.response(Some(id))),
                        };
                        api.sweep(host);
                        if let Some(reply) = reply {
                            queue_reply(reply, host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::API_CIRCUIT_SNAPSHOT | methods::API_CIRCUIT_RESET
                ) {
                    if let Some(id) = id.as_ref() {
                        let reply = match api.circuit_rpc(host, &method, params) {
                            Ok(value) => protocol::success(id, value),
                            Err(fault) => fault.response(Some(id)),
                        };
                        queue_reply(reply, host.frame_limit(), tx, permits)?;
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::EXECUTE
                        | methods::LIST_FILES
                        | methods::GREP
                        | methods::GIT_STATUS
                        | methods::GIT_READ
                        | methods::GIT_MUTATION
                        | methods::JOB_START
                ) {
                    if let Some(id) = id.as_ref() {
                        let admitted = if method == methods::LIST_FILES {
                            commands.start_listing(host, id.clone(), params)
                        } else if method == methods::GREP {
                            commands.start_grep(host, id.clone(), params)
                        } else if method == methods::GIT_STATUS {
                            commands.start_git_status(host, id.clone(), params)
                        } else if method == methods::GIT_READ {
                            commands.start_git_read(host, id.clone(), params)
                        } else if method == methods::GIT_MUTATION {
                            commands.start_git_mutation(host, id.clone(), params)
                        } else if method == methods::JOB_START {
                            commands.start_job(host, id.clone(), params)
                        } else {
                            commands.start(host, id.clone(), params)
                        };
                        if let Err(fault) = admitted {
                            queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                if method == methods::EDIT_AUTHORIZE {
                    if let Some(id) = id.as_ref()
                        && let Err(fault) = commands.authorize_editor(host, id.clone(), params)
                    {
                        queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                    }
                    continue;
                }
                if method == methods::EDIT_DECISION {
                    if let Some(id) = id.as_ref() {
                        let reply = match commands.decide_editor(host, params) {
                            Ok(value) => protocol::success(id, value),
                            Err(fault) => fault.response(Some(id)),
                        };
                        queue_reply(reply, host.frame_limit(), tx, permits)?;
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::EDIT_PREPARE | methods::EDIT_INSPECT
                ) {
                    if let Some(id) = id.as_ref() {
                        let admitted = host
                            .prepare_edit(params, method == methods::EDIT_INSPECT)
                            .and_then(|(scope, input)| {
                                use crate::edit::prepare::PrepareWork;
                                let ticket = match &input {
                                    PrepareWork::Read(work) => work.id.clone(),
                                    PrepareWork::Patch(work) => work.id.clone(),
                                };
                                let admitted = match input {
                                    PrepareWork::Read(work) => {
                                        reads.start_edit(id.clone(), scope.clone(), work)
                                    }
                                    PrepareWork::Patch(work) => commands.start_edit_patch(
                                        host,
                                        id.clone(),
                                        scope.clone(),
                                        work,
                                    ),
                                };
                                if admitted.is_err() {
                                    // Admission failed before a worker existed; release the staging slot.
                                    let _ = host.finish_edit(
                                        &scope,
                                        &ticket,
                                        Err(crate::error::CoreError::Limit),
                                    );
                                }
                                admitted
                            });
                        if let Err(fault) = admitted {
                            queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                if method == methods::CONFIGURATION_READ {
                    if let Some(id) = id.as_ref() {
                        let admitted =
                            host.prepare_configuration_read(params)
                                .and_then(|(scope, input)| {
                                    reads.start_configuration(id.clone(), scope, input)
                                });
                        if let Err(fault) = admitted {
                            queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::FIND_FILES
                        | methods::READ_FILE
                        | methods::SKILLS
                        | methods::WEBFETCH
                        | methods::PROBE
                ) {
                    if let Some(id) = id.as_ref() {
                        let admitted = host
                            .prepare_workspace_read(&method, params)
                            .and_then(|(scope, input)| reads.start(id.clone(), scope, input));
                        if let Err(fault) = admitted {
                            queue_reply(fault.response(Some(id)), host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                if matches!(
                    method.as_str(),
                    methods::JOB_LIST
                        | methods::JOB_CLAIM
                        | methods::JOB_STATUS
                        | methods::JOB_READ
                        | methods::JOB_WRITE
                        | methods::JOB_EOF
                        | methods::JOB_CANCEL
                        | methods::JOB_FORGET
                ) {
                    if let Some(id) = id.as_ref() {
                        let reply = match commands.job_rpc(host, id.clone(), &method, params) {
                            Ok(Some(value)) => Some(protocol::success(id, value)),
                            Ok(None) => None,
                            Err(fault) => Some(fault.response(Some(id))),
                        };
                        if let Some(reply) = reply {
                            queue_reply(reply, host.frame_limit(), tx, permits)?;
                        }
                    }
                    continue;
                }
                let dispatch = host.dispatch(&method, params, id.is_some());
                let draining_shutdown = method == methods::SHUTDOWN && dispatch.result.is_ok();
                reads.sweep(host);
                api.sweep(host);
                if dispatch.exit {
                    return Ok(());
                }
                input.decoder_mut().lines =
                    LinesCodec::new_with_max_length(host.frame_limit().as_usize());
                if host.is_shutdown() {
                    pending.disconnect();
                }
                let reply = id.as_ref().map(|id| match dispatch.result {
                    Ok(result) => protocol::success(id, result),
                    Err(fault) => fault.response(Some(id)),
                });
                if draining_shutdown
                    && (!reads.is_empty()
                        || !commands.is_empty()
                        || !api.is_empty()
                        || !lifecycle.is_empty())
                {
                    shutdown_reply = reply;
                    None
                } else {
                    reply
                }
            }
        };
        if let Some(reply) = reply {
            queue_reply(reply, host.frame_limit(), tx, permits)?;
        }
    }
}

fn queue_reply(
    reply: Value,
    limit: ByteLimit,
    tx: &mpsc::Sender<Frame>,
    permits: &Arc<Semaphore>,
) -> Result<(), TransportError> {
    let mut line = serde_json::to_string(&reply).map_err(|_| TransportError::Framing)?;
    if line.len() > limit.as_usize() {
        let id = reply.get("id").and_then(protocol::RpcId::parse);
        line = serde_json::to_string(
            &protocol::Fault {
                code: crate::constants::protocol::error_codes::RESOURCE_LIMIT,
                message: "Response exceeds negotiated frame limit",
                status: "resource_limit",
            }
            .response(id.as_ref()),
        )
        .map_err(|_| TransportError::Framing)?;
        if line.len() > limit.as_usize() {
            return Err(TransportError::Overloaded);
        }
    }
    let bytes =
        u32::try_from(line.len().saturating_add(1)).map_err(|_| TransportError::Overloaded)?;
    let permit = permits
        .clone()
        .try_acquire_many_owned(bytes)
        .map_err(|_| TransportError::Overloaded)?;
    tx.try_send(Frame {
        line,
        _permit: permit,
    })
    .map_err(|_| TransportError::Overloaded)
}
