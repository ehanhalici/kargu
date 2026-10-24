//! Approved, owner-scoped Unix subprocesses with bounded IO and explicit drain.
//!
//! The leader is observed with WNOWAIT and reaped only after the final group
//! signal, pinning its PGID against reuse during cleanup. setsid escape and
//! abrupt host death still require a separate OS containment capability.

use crate::{
    application::{ApplicationActor, RunHandle, RunLease, ToolOutcome},
    constants::{limits, timeouts},
    domain::{ByteLimit, ByteOffset, JobId, ToolCallId},
    error::CoreError,
    security::AuthorizedCommand,
};
use nix::{
    errno::Errno,
    sys::{
        prctl::set_child_subreaper,
        signal::{Signal, killpg},
        wait::{Id, WaitPidFlag, WaitStatus, waitid, waitpid},
    },
    unistd::Pid,
};
use std::os::unix::process::ExitStatusExt;
use std::{
    collections::HashMap,
    process::{ExitStatus, Stdio},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, Command},
    sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};
use tokio_util::{sync::CancellationToken, task::AbortOnDropHandle};

/// Configuration DTO for bounded cleanup; independent of command/run deadlines.
pub struct CleanupSettings {
    /// TERM grace; must be positive.
    pub grace: Duration,
    /// Drain and reap deadline; must be positive.
    pub drain: Duration,
}

/// Validated TERM/KILL/drain configuration.
#[derive(Clone, Copy)]
pub struct CleanupPolicy {
    grace: Duration,
    drain: Duration,
}
impl Default for CleanupPolicy {
    fn default() -> Self {
        Self {
            grace: timeouts::PROCESS_GRACE,
            drain: timeouts::PROCESS_DRAIN,
        }
    }
}
impl TryFrom<CleanupSettings> for CleanupPolicy {
    type Error = CoreError;
    fn try_from(value: CleanupSettings) -> Result<Self, CoreError> {
        if value.grace.is_zero()
            || value.drain.is_zero()
            || Instant::now().checked_add(value.grace).is_none()
            || Instant::now().checked_add(value.drain).is_none()
        {
            Err(CoreError::InvalidValue {
                field: "CleanupPolicy",
            })
        } else {
            Ok(Self {
                grace: value.grace,
                drain: value.drain,
            })
        }
    }
}

/// Bounded input message; no unbounded writer buffer can be enqueued.
pub struct InputChunk(Vec<u8>);
impl TryFrom<Vec<u8>> for InputChunk {
    type Error = CoreError;
    fn try_from(value: Vec<u8>) -> Result<Self, CoreError> {
        if value.len() > limits::PROCESS_PAGE_BYTES {
            Err(CoreError::Limit)
        } else {
            Ok(Self(value))
        }
    }
}

/// Which independently archived byte stream to read.
#[derive(Clone, Copy)]
pub enum OutputStream {
    /// Standard output.
    Stdout,
    /// Standard error, never mixed into stdout.
    Stderr,
}

/// A lossless byte page; UTF-8 decoding belongs to the consumer after reassembly.
pub struct OutputPage {
    /// Retained bytes, at most one page.
    pub bytes: Vec<u8>,
    /// Absolute cursor, including any explicitly skipped truncated interval.
    pub next_cursor: ByteOffset,
    /// Some observed output exceeded the retention bound.
    pub truncated: bool,
    /// The pipe has closed.
    pub eof: bool,
}

#[derive(Default)]
struct Archive {
    bytes: Vec<u8>,
    seen: ByteOffset,
    truncated: bool,
    eof: bool,
}
impl Archive {
    fn push(&mut self, bytes: &[u8], run: &RunHandle) -> Result<(), CoreError> {
        self.seen = self.seen.checked_add(ByteOffset::try_from(
            u64::try_from(bytes.len()).map_err(|_| CoreError::ArithmeticOverflow)?,
        )?)?;
        let room = limits::PROCESS_OUTPUT_BYTES
            .saturating_sub(self.bytes.len())
            .min(bytes.len());
        let keep = if room == 0 {
            0
        } else {
            run.reserve_output(ByteLimit::try_from(room)?)
        };
        self.bytes.extend(bytes.iter().take(keep));
        self.truncated |= keep < bytes.len();
        Ok(())
    }
    fn page(&self, cursor: ByteOffset) -> Result<OutputPage, CoreError> {
        if cursor > self.seen {
            return Err(CoreError::InvalidValue {
                field: "OutputCursor",
            });
        }
        let start = usize::try_from(cursor.as_u64()).map_err(|_| CoreError::ArithmeticOverflow)?;
        let mut bytes = Vec::new();
        if let Some(retained) = self.bytes.get(start..) {
            bytes.extend(retained.iter().take(limits::PROCESS_PAGE_BYTES));
        }
        let end = start
            .checked_add(bytes.len())
            .ok_or(CoreError::ArithmeticOverflow)?;
        let next_cursor = if end >= self.bytes.len() {
            self.seen
        } else {
            ByteOffset::try_from(u64::try_from(end).map_err(|_| CoreError::ArithmeticOverflow)?)?
        };
        Ok(OutputPage {
            bytes,
            next_cursor,
            truncated: self.truncated,
            eof: self.eof,
        })
    }
}

enum InputMessage {
    Write(InputChunk, oneshot::Sender<Result<(), CoreError>>),
    Eof(oneshot::Sender<Result<(), CoreError>>),
}

/// Typed process terminal data. Output remains in separately bounded archives.
#[derive(Debug)]
pub struct ProcessResult {
    /// Success/failure/cancel/timeout/unknown, independent of the message text.
    pub outcome: ToolOutcome,
    /// Exit code, absent for signal termination or unknown exit.
    pub exit_code: Option<i32>,
    /// Unix termination signal, independent of the exit code.
    pub signal: Option<i32>,
    /// All tracked tasks and the direct child were drained/reaped.
    pub cleanup_complete: bool,
}

/// Single-delivery completion. Its run lease stays live until the actor consumes it.
pub struct JobCompletion {
    run: RunHandle,
    call_id: ToolCallId,
    result: ProcessResult,
    _lease: RunLease,
}
impl JobCompletion {
    /// Inspect typed terminal data before handing it to the owner actor.
    pub fn result(&self) -> &ProcessResult {
        &self.result
    }
    /// Deliver exactly once to the owning actor, outside any I/O callback.
    pub fn deliver(self, actor: &mut ApplicationActor) -> Result<ProcessResult, CoreError> {
        if !self.result.cleanup_complete {
            actor.quarantine(&self.run)?;
        }
        actor.complete_tool(&self.run, &self.call_id, self.result.outcome)?;
        Ok(self.result)
    }
}

struct Job {
    run: RunHandle,
    cancel: CancellationToken,
    input: mpsc::Sender<InputMessage>,
    stdout: Arc<Mutex<Archive>>,
    stderr: Arc<Mutex<Archive>>,
    task: Option<JoinHandle<JobCompletion>>,
}

/// Resource state for polling; completion-ready is not a published tool result.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JobStatus {
    /// Executor or cleanup is still active.
    Running,
    /// Cancellation requested; drain/reap is still pending.
    Cancelling,
    /// Cleanup finished and one completion can be collected.
    CompletionReady,
    /// The completion was already taken; retained output remains readable.
    Collected,
}

/// Host process service. Async waits never borrow or block an ApplicationActor.
pub struct ProcessSupervisor {
    jobs: HashMap<JobId, Job>,
    slots: Arc<Semaphore>,
    cleanup: CleanupPolicy,
}
impl ProcessSupervisor {
    /// Construct the Linux core's process owner and enable child subreaping.
    /// This explicit process-wide setting is retained for the core lifetime;
    /// waits below are scoped to owned groups, never waitpid(-1).
    pub fn new(cleanup: CleanupPolicy) -> Result<Self, CoreError> {
        set_child_subreaper(true).map_err(|_| CoreError::CleanupFailed)?;
        Ok(Self {
            jobs: HashMap::new(),
            slots: Arc::new(Semaphore::new(limits::HOST_PROCESSES)),
            cleanup,
        })
    }
    /// Spawn only an approved command, revalidating owner, deadline, cwd and executable.
    pub fn start(
        &mut self,
        actor: &mut ApplicationActor,
        authorized: AuthorizedCommand,
    ) -> Result<JobId, CoreError> {
        let (child, slots) = match self.spawn_approved(actor, &authorized) {
            Ok(spawned) => spawned,
            Err(error) => {
                if actor.validate_owner(authorized.run()).is_ok() {
                    let outcome = match error {
                        CoreError::Cancelled => ToolOutcome::Cancelled,
                        CoreError::Deadline | CoreError::ApprovalExpired => ToolOutcome::Timeout,
                        CoreError::Rejected | CoreError::WorkspaceChanged => ToolOutcome::Rejected,
                        _ => ToolOutcome::Failed,
                    };
                    let _ = actor.complete_tool(authorized.run(), authorized.call_id(), outcome);
                }
                return Err(error);
            }
        };
        let cancel = authorized.run().cancel_token();
        let stdout = Arc::new(Mutex::new(Archive::default()));
        let stderr = Arc::new(Mutex::new(Archive::default()));
        let (input, rx) = mpsc::channel(limits::PROCESS_INPUT_QUEUE);
        let job_id = JobId::new();
        let run = authorized.run().clone();
        let task = tokio::spawn(supervise(
            child,
            authorized,
            Streams {
                stdout: stdout.clone(),
                stderr: stderr.clone(),
            },
            rx,
            cancel.clone(),
            self.cleanup,
            slots,
        ));
        self.jobs.insert(
            job_id.clone(),
            Job {
                run,
                cancel,
                input,
                stdout,
                stderr,
                task: Some(task),
            },
        );
        Ok(job_id)
    }

    fn spawn_approved(
        &self,
        actor: &mut ApplicationActor,
        authorized: &AuthorizedCommand,
    ) -> Result<(Child, Slots), CoreError> {
        tokio::runtime::Handle::try_current().map_err(|_| CoreError::Unavailable)?;
        authorized.revalidate(actor)?;
        if self.jobs.len() >= limits::JOBS {
            return Err(CoreError::Limit);
        }
        let host_slot = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| CoreError::Limit)?;
        let run_slot = authorized
            .run()
            .process_slots()
            .try_acquire_owned()
            .map_err(|_| CoreError::Limit)?;
        actor.mark_started(authorized.run(), authorized.call_id())?;
        let spec = authorized.command();
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.arguments)
            .current_dir(spec.cwd.path())
            .env_clear()
            .envs(spec.environment.entries())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .kill_on_drop(true);
        Ok((
            command.spawn()?,
            Slots {
                _host: host_slot,
                _run: run_slot,
            },
        ))
    }
    fn job(&self, run: &RunHandle, id: &JobId) -> Result<&Job, CoreError> {
        self.jobs
            .get(id)
            .filter(|job| job.run.same_owner(run))
            .ok_or(CoreError::StaleOwner)
    }
    /// Poll only this run's owned resource, without waiting on its child.
    pub fn status(&self, run: &RunHandle, id: &JobId) -> Result<JobStatus, CoreError> {
        let job = self.job(run, id)?;
        Ok(match &job.task {
            None => JobStatus::Collected,
            Some(task) if task.is_finished() => JobStatus::CompletionReady,
            Some(_) if job.cancel.is_cancelled() => JobStatus::Cancelling,
            Some(_) => JobStatus::Running,
        })
    }
    /// Read a bounded page without requiring the job to have exited.
    pub async fn read(
        &self,
        run: &RunHandle,
        id: &JobId,
        stream: OutputStream,
        cursor: ByteOffset,
    ) -> Result<OutputPage, CoreError> {
        let job = self.job(run, id)?;
        let archive = match stream {
            OutputStream::Stdout => &job.stdout,
            OutputStream::Stderr => &job.stderr,
        };
        archive.lock().await.page(cursor)
    }
    /// Send a bounded input chunk; the acknowledgement means it reached the pipe.
    pub async fn write(
        &self,
        run: &RunHandle,
        id: &JobId,
        chunk: InputChunk,
    ) -> Result<(), CoreError> {
        run.check_live()?;
        let job = self.job(run, id)?;
        let (tx, rx) = oneshot::channel();
        job.input
            .try_send(InputMessage::Write(chunk, tx))
            .map_err(|_| CoreError::Limit)?;
        rx.await.map_err(|_| CoreError::Cancelled)?
    }
    /// Close stdin once, preserving output drain until the process actually exits.
    pub async fn eof(&self, run: &RunHandle, id: &JobId) -> Result<(), CoreError> {
        let job = self.job(run, id)?;
        let (tx, rx) = oneshot::channel();
        job.input
            .try_send(InputMessage::Eof(tx))
            .map_err(|_| CoreError::AlreadyCompleted)?;
        rx.await.map_err(|_| CoreError::Cancelled)?
    }
    /// Cancel one job without cancelling its run, siblings or other applications.
    pub fn cancel(&self, run: &RunHandle, id: &JobId) -> Result<(), CoreError> {
        self.job(run, id)?.cancel.cancel();
        Ok(())
    }
    /// Collect once. If this future is cancelled, its task remains supervised.
    pub async fn wait(&mut self, run: &RunHandle, id: &JobId) -> Result<JobCompletion, CoreError> {
        self.job(run, id)?;
        let job = self.jobs.get_mut(id).ok_or(CoreError::StaleOwner)?;
        let task = job.task.as_mut().ok_or(CoreError::AlreadyCompleted)?;
        let completed = task.await.map_err(|_| CoreError::CleanupFailed);
        job.task = None;
        completed
    }
    /// Drop retained output only after the terminal completion has been collected.
    pub fn forget(&mut self, run: &RunHandle, id: &JobId) -> Result<(), CoreError> {
        if self.job(run, id)?.task.is_some() {
            return Err(CoreError::Busy);
        }
        self.jobs.remove(id);
        Ok(())
    }
    /// List only this run's owned jobs, including retained terminal archives.
    pub fn jobs(&self, run: &RunHandle) -> Vec<JobId> {
        self.jobs
            .iter()
            .filter(|(_, j)| j.run.same_owner(run))
            .map(|(id, _)| id.clone())
            .collect()
    }
}
impl Drop for ProcessSupervisor {
    fn drop(&mut self) {
        // Do not abort the tasks: their TERM/KILL/wait cleanup must still run.
        // Abrupt runtime/process death needs a separate OS supervisor capability.
        for job in self.jobs.values() {
            job.cancel.cancel();
        }
    }
}

struct Slots {
    _host: OwnedSemaphorePermit,
    _run: OwnedSemaphorePermit,
}
struct Streams {
    stdout: Arc<Mutex<Archive>>,
    stderr: Arc<Mutex<Archive>>,
}
struct ProcessGroup(Pid);
impl ProcessGroup {
    fn capture(child: &Child) -> Result<Self, CoreError> {
        let raw = child.id().ok_or(CoreError::CleanupFailed)?;
        let raw = i32::try_from(raw).map_err(|_| CoreError::CleanupFailed)?;
        if raw <= 0 {
            return Err(CoreError::CleanupFailed);
        }
        Ok(Self(Pid::from_raw(raw)))
    }
    fn exited(&self) -> Result<bool, CoreError> {
        match waitid(
            Id::Pid(self.0),
            WaitPidFlag::WEXITED | WaitPidFlag::WNOHANG | WaitPidFlag::WNOWAIT,
        ) {
            Ok(WaitStatus::StillAlive) => Ok(false),
            Ok(WaitStatus::Exited(_, _) | WaitStatus::Signaled(_, _, _)) => Ok(true),
            Ok(_) => Ok(false),
            Err(Errno::EINTR) => Ok(false),
            // Ownership is no longer established. Never signal a reusable number.
            Err(_) => Err(CoreError::CleanupFailed),
        }
    }
    fn signal(&self, signal: Signal) -> Result<(), CoreError> {
        // WNOWAIT has retained the leader, reserving the group identity.
        self.exited()?;
        match killpg(self.0, signal) {
            Ok(()) | Err(Errno::ESRCH) => Ok(()),
            Err(_) => Err(CoreError::CleanupFailed),
        }
    }
}

async fn drain<R: AsyncRead + Unpin>(
    mut pipe: R,
    archive: Arc<Mutex<Archive>>,
    run: RunHandle,
) -> Result<(), CoreError> {
    let mut buffer = vec![0_u8; limits::PROCESS_PAGE_BYTES];
    loop {
        let count = pipe.read(&mut buffer).await?;
        if count == 0 {
            archive.lock().await.eof = true;
            return Ok(());
        }
        let chunk = buffer.get(..count).ok_or(CoreError::CleanupFailed)?;
        archive.lock().await.push(chunk, &run)?;
    }
}

async fn input_loop(
    mut pipe: ChildStdin,
    mut rx: mpsc::Receiver<InputMessage>,
    cancel: CancellationToken,
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
                    result = pipe.write_all(&chunk.0) => result.map_err(CoreError::Io),
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

async fn join_drain(
    task: &mut AbortOnDropHandle<Result<(), CoreError>>,
    deadline: Instant,
) -> bool {
    match tokio::time::timeout_at(deadline, &mut *task).await {
        Ok(Ok(Ok(()))) => true,
        Ok(_) => false,
        Err(_) => {
            task.abort();
            let _ = task.await;
            false
        }
    }
}

async fn supervise(
    mut child: Child,
    authorized: AuthorizedCommand,
    streams: Streams,
    rx: mpsc::Receiver<InputMessage>,
    cancel: CancellationToken,
    cleanup: CleanupPolicy,
    _slots: Slots,
) -> JobCompletion {
    let crate::security::ApprovedParts {
        run,
        call_id,
        command,
        lease,
        ..
    } = authorized.into_parts();
    let result = supervise_child(&mut child, &run, &command, streams, rx, cancel, cleanup).await;
    JobCompletion {
        run,
        call_id,
        result,
        _lease: lease,
    }
}

async fn supervise_child(
    child: &mut Child,
    run: &RunHandle,
    command: &crate::security::CommandSpec,
    streams: Streams,
    rx: mpsc::Receiver<InputMessage>,
    cancel: CancellationToken,
    cleanup: CleanupPolicy,
) -> ProcessResult {
    let Some(stdout) = child.stdout.take() else {
        return unknown_result();
    };
    let Some(stderr) = child.stderr.take() else {
        return unknown_result();
    };
    let Some(stdin) = child.stdin.take() else {
        return unknown_result();
    };
    let Ok(group) = ProcessGroup::capture(child) else {
        return unknown_result();
    };
    let mut out_task =
        AbortOnDropHandle::new(tokio::spawn(drain(stdout, streams.stdout, run.clone())));
    let mut err_task =
        AbortOnDropHandle::new(tokio::spawn(drain(stderr, streams.stderr, run.clone())));
    let input_cancel = cancel.child_token();
    let mut input_task =
        AbortOnDropHandle::new(tokio::spawn(input_loop(stdin, rx, input_cancel.clone())));
    let deadline = Instant::now()
        .checked_add(command.timeout)
        .unwrap_or(run.deadline())
        .min(run.deadline());
    let mut poll = tokio::time::interval(timeouts::PROCESS_POLL);
    let mut cleanup_ok = true;
    let mut outcome = loop {
        tokio::select! { biased;
            _ = cancel.cancelled() => break ToolOutcome::Cancelled,
            _ = tokio::time::sleep_until(deadline) => break ToolOutcome::Timeout,
            _ = poll.tick() => match group.exited() {
                Ok(true) => break ToolOutcome::Ok,
                Ok(false) => {},
                Err(_) => {cleanup_ok=false; break ToolOutcome::OutcomeUnknown},
            }
        }
    };
    input_cancel.cancel();
    if cleanup_ok {
        cleanup_ok &= group.signal(Signal::SIGTERM).is_ok();
        if outcome == ToolOutcome::Ok {
            // A foreground leader has exited: finish output drain before final group cleanup.
            let until = Instant::now()
                .checked_add(cleanup.grace)
                .unwrap_or_else(Instant::now);
            while !(out_task.is_finished() && err_task.is_finished()) && Instant::now() < until {
                tokio::time::sleep(timeouts::PROCESS_POLL).await;
            }
        } else {
            tokio::time::sleep(cleanup.grace).await;
        }
        cleanup_ok &= group.signal(Signal::SIGKILL).is_ok();
    }
    // Last signal always precedes wait/reap: the unreaped leader pins the PGID.
    let until = Instant::now()
        .checked_add(cleanup.drain)
        .unwrap_or_else(Instant::now);
    let status = match tokio::time::timeout_at(until, child.wait()).await {
        Ok(Ok(status)) => Some(status),
        _ => {
            cleanup_ok = false;
            None
        }
    };
    if cleanup_ok {
        cleanup_ok &= reap_adopted(&group, until).await;
    }
    cleanup_ok &= join_drain(&mut out_task, until).await;
    cleanup_ok &= join_drain(&mut err_task, until).await;
    match tokio::time::timeout_at(until, &mut input_task).await {
        Ok(Ok(())) => {}
        Ok(_) => cleanup_ok = false,
        Err(_) => {
            input_task.abort();
            let _ = input_task.await;
            cleanup_ok = false
        }
    }
    if !cleanup_ok {
        outcome = ToolOutcome::OutcomeUnknown;
    } else if outcome == ToolOutcome::Ok && status.as_ref().is_none_or(|s| !s.success()) {
        outcome = ToolOutcome::Failed;
    }
    ProcessResult {
        outcome,
        exit_code: status.as_ref().and_then(ExitStatus::code),
        signal: status.as_ref().and_then(ExitStatusExt::signal),
        cleanup_complete: cleanup_ok,
    }
}

fn unknown_result() -> ProcessResult {
    ProcessResult {
        outcome: ToolOutcome::OutcomeUnknown,
        exit_code: None,
        signal: None,
        cleanup_complete: false,
    }
}

async fn reap_adopted(group: &ProcessGroup, deadline: Instant) -> bool {
    loop {
        match waitpid(Pid::from_raw(-group.0.as_raw()), Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::StillAlive) => {
                if Instant::now() >= deadline {
                    return false;
                }
                tokio::time::sleep(timeouts::PROCESS_POLL).await;
            }
            Ok(_) | Err(Errno::EINTR) => {}
            Err(Errno::ECHILD) => return true,
            Err(_) => return false,
        }
    }
}
