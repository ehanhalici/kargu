//! Asynchronous bounded persistence worker, epoch tracking, and typed completions.
//!
//! Enforces:
//! - Bounded queue capacity (max pending jobs, max pending bytes) and deadline validation before admission.
//! - Non-blocking actor mailbox: slow fsync cannot block ping, abort, or close requests.
//! - Typed completions verifying epoch, session_id, and revision before publication.
//! - Accurate durability reporting: cancellation never pretends durable writes did not occur.

use crate::{
    constants::limits,
    error::CoreError,
    persistence::{
        domain::{
            ListTruncation, PersistenceError, RetentionReport, SessionListResult, SessionRecord,
            SessionRetentionPolicy, StorageRevision, StorageSessionId,
        },
        layout::StorageLocation,
        migration::{CollisionPolicy, SessionCandidate, migrate_candidate},
        recovery::read_import_source,
        storage::{SessionLock, SessionStorage, resolve_location},
    },
};
use std::{
    collections::{BTreeSet, HashMap},
    sync::Arc,
    time::Instant,
};
use tokio_util::sync::CancellationToken;

/// Monotonic epoch for worker-actor lifecycle transitions.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct StorageEpoch(u64);

impl StorageEpoch {
    /// Return the raw integer counter.
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Construct from raw counter.
    pub const fn from_u64(val: u64) -> Self {
        Self(val)
    }

    /// Increment monotonically.
    pub fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }
}

/// Durable commit confirmation state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Durability {
    /// Write was successfully synced to durable storage.
    Durable,
    /// Operation did not reach durable sync.
    Volatile,
}

/// Typed outcome of an asynchronous persistence operation.
#[derive(Debug)]
pub enum PersistenceCompletion {
    /// Snapshot was committed to durable storage.
    SnapshotSaved {
        /// Execution epoch.
        epoch: StorageEpoch,
        /// Session identifier.
        session_id: StorageSessionId,
        /// Persisted revision.
        revision: StorageRevision,
        /// Durability status.
        durability: Durability,
    },
    /// Snapshot was loaded from storage.
    SnapshotLoaded {
        /// Execution epoch.
        epoch: StorageEpoch,
        /// Session identifier.
        session_id: StorageSessionId,
        /// Loaded record if present.
        record: Option<Box<SessionRecord>>,
    },
    /// Session was deleted from storage.
    SessionDeleted {
        /// Execution epoch.
        epoch: StorageEpoch,
        /// Session identifier.
        session_id: StorageSessionId,
        /// Durability status.
        durability: Durability,
    },
    /// Session candidate was imported into storage.
    CandidateImported {
        /// Execution epoch.
        epoch: StorageEpoch,
        /// Session identifier.
        session_id: StorageSessionId,
        /// Durability status.
        durability: Durability,
    },
    /// Operation failed.
    Failed {
        /// Execution epoch.
        epoch: StorageEpoch,
        /// Session identifier.
        session_id: StorageSessionId,
        /// Failure error.
        error: CoreError,
        /// Durability status.
        durability: Durability,
    },
}

impl PersistenceCompletion {
    /// Epoch of the completion.
    pub fn epoch(&self) -> StorageEpoch {
        match self {
            Self::SnapshotSaved { epoch, .. }
            | Self::SnapshotLoaded { epoch, .. }
            | Self::SessionDeleted { epoch, .. }
            | Self::CandidateImported { epoch, .. }
            | Self::Failed { epoch, .. } => *epoch,
        }
    }

    /// Session identifier of the completion.
    pub fn session_id(&self) -> &StorageSessionId {
        match self {
            Self::SnapshotSaved { session_id, .. }
            | Self::SnapshotLoaded { session_id, .. }
            | Self::SessionDeleted { session_id, .. }
            | Self::CandidateImported { session_id, .. }
            | Self::Failed { session_id, .. } => session_id,
        }
    }

    /// Durability status of the completion.
    pub fn durability(&self) -> Durability {
        match self {
            Self::SnapshotSaved { durability, .. }
            | Self::SessionDeleted { durability, .. }
            | Self::CandidateImported { durability, .. }
            | Self::Failed { durability, .. } => *durability,
            Self::SnapshotLoaded { .. } => Durability::Volatile,
        }
    }
}

/// Result of evaluating a worker completion against actor state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompletionVerdict {
    /// Completion matches current epoch and revision; publication admitted.
    Valid,
    /// Epoch mismatch: completion originated from a superseded or aborted turn.
    StaleEpoch,
    /// Revision mismatch: completion does not match the expected monotonic revision.
    StaleRevision,
}

/// Request to write a snapshot.
pub struct SaveRequest {
    session_id: StorageSessionId,
    revision: StorageRevision,
    record: SessionRecord,
}

impl SaveRequest {
    /// Create a new snapshot write request.
    pub fn new(
        session_id: StorageSessionId,
        revision: StorageRevision,
        record: SessionRecord,
    ) -> Self {
        Self {
            session_id,
            revision,
            record,
        }
    }

    /// Target session identifier.
    pub fn session_id(&self) -> &StorageSessionId {
        &self.session_id
    }

    /// Monotonic write revision.
    pub fn revision(&self) -> StorageRevision {
        self.revision
    }

    /// Record to persist.
    pub fn record(&self) -> &SessionRecord {
        &self.record
    }
}

struct SessionTrack {
    epoch: StorageEpoch,
    expected_revision: StorageRevision,
    published_revision: Option<StorageRevision>,
}

/// Actor-side persistence coordinator managing epochs, admission limits, and publications.
pub struct PersistenceService {
    storage: Arc<SessionStorage>,
    sessions: HashMap<StorageSessionId, SessionTrack>,
    pending_jobs: usize,
    pending_bytes: usize,
    max_pending_jobs: usize,
    max_pending_bytes: usize,
    closed: bool,
}

impl PersistenceService {
    /// Create a new coordinator with bounded admission limits.
    pub fn new(storage: Arc<SessionStorage>) -> Self {
        Self {
            storage,
            sessions: HashMap::new(),
            pending_jobs: 0,
            pending_bytes: 0,
            max_pending_jobs: 16,
            max_pending_bytes: limits::SESSION_MAX_FILE_BYTES.saturating_mul(2),
            closed: false,
        }
    }

    /// Immediately verify mailbox responsiveness without waiting on disk IO.
    pub fn ping(&self) -> Result<(), CoreError> {
        if self.closed {
            Err(CoreError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// Abort active persistence operations for a session by advancing its epoch.
    pub fn abort(&mut self, session_id: &StorageSessionId) {
        if let Some(track) = self.sessions.get_mut(session_id) {
            track.epoch = track.epoch.next();
        }
    }

    /// Close the service against new admissions.
    pub fn close(&mut self) {
        self.closed = true;
    }

    /// Current epoch for a session.
    pub fn current_epoch(&self, session_id: &StorageSessionId) -> StorageEpoch {
        self.sessions
            .get(session_id)
            .map_or(StorageEpoch::default(), |t| t.epoch)
    }

    /// Currently published revision for a session.
    pub fn published_revision(&self, session_id: &StorageSessionId) -> Option<StorageRevision> {
        self.sessions
            .get(session_id)
            .and_then(|t| t.published_revision)
    }

    /// Submit a snapshot write to the background worker.
    pub fn submit_save(
        &mut self,
        request: SaveRequest,
        deadline: Instant,
    ) -> Result<tokio::task::JoinHandle<PersistenceCompletion>, CoreError> {
        self.check_admission(deadline, limits::SESSION_MAX_FILE_BYTES)?;
        let epoch = self.advance_or_init_track(&request.session_id, request.revision);
        let task = ServiceSaveTask {
            storage: Arc::clone(&self.storage),
            epoch,
            session_id: request.session_id,
            revision: request.revision,
            record: request.record,
        };
        Ok(tokio::task::spawn_blocking(move || execute_save(task)))
    }

    /// Submit a candidate import to the background worker.
    pub fn submit_import(
        &mut self,
        candidate: SessionCandidate,
        deadline: Instant,
    ) -> Result<tokio::task::JoinHandle<PersistenceCompletion>, CoreError> {
        self.check_admission(deadline, limits::SESSION_MAX_FILE_BYTES)?;
        let session_id = candidate.id().clone();
        let epoch = self.advance_or_init_track(&session_id, StorageRevision::from_u64(1));
        let task = ServiceImportTask {
            storage: Arc::clone(&self.storage),
            epoch,
            session_id,
            candidate,
        };
        Ok(tokio::task::spawn_blocking(move || execute_import(task)))
    }

    /// Clear and advance epoch for a deleted session so in-flight tasks become stale.
    pub fn delete_session_track(&mut self, session_id: &StorageSessionId) {
        let entry = self
            .sessions
            .entry(session_id.clone())
            .or_insert_with(|| SessionTrack {
                epoch: StorageEpoch::default(),
                expected_revision: StorageRevision::from_u64(0),
                published_revision: None,
            });
        entry.epoch = entry.epoch.next();
        entry.expected_revision = StorageRevision::from_u64(0);
        entry.published_revision = None;
    }

    /// Submit a session deletion to the background worker.
    pub fn submit_delete(
        &mut self,
        session_id: StorageSessionId,
        deadline: Instant,
    ) -> Result<tokio::task::JoinHandle<PersistenceCompletion>, CoreError> {
        self.check_admission(deadline, 1024)?;
        self.delete_session_track(&session_id);
        let epoch = self.current_epoch(&session_id);
        let task = ServiceDeleteTask {
            storage: Arc::clone(&self.storage),
            epoch,
            session_id,
        };
        Ok(tokio::task::spawn_blocking(move || {
            execute_service_delete(task)
        }))
    }

    /// Validate a completed worker result against actor epoch and revision state.
    pub fn validate_completion(&mut self, completion: &PersistenceCompletion) -> CompletionVerdict {
        self.release_pending(limits::SESSION_MAX_FILE_BYTES);
        let Some(track) = self.sessions.get_mut(completion.session_id()) else {
            return CompletionVerdict::StaleEpoch;
        };
        if completion.epoch() != track.epoch {
            return CompletionVerdict::StaleEpoch;
        }
        if let PersistenceCompletion::SnapshotSaved { revision, .. } = completion {
            if *revision != track.expected_revision {
                return CompletionVerdict::StaleRevision;
            }
            track.published_revision = Some(*revision);
        }
        CompletionVerdict::Valid
    }

    fn check_admission(&mut self, deadline: Instant, byte_cost: usize) -> Result<(), CoreError> {
        if self.closed {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        if self.pending_jobs >= self.max_pending_jobs {
            return Err(CoreError::Busy);
        }
        let next_bytes = self.pending_bytes.saturating_add(byte_cost);
        if next_bytes > self.max_pending_bytes {
            return Err(CoreError::Limit);
        }
        self.pending_jobs = self.pending_jobs.saturating_add(1);
        self.pending_bytes = next_bytes;
        Ok(())
    }

    fn advance_or_init_track(
        &mut self,
        session_id: &StorageSessionId,
        revision: StorageRevision,
    ) -> StorageEpoch {
        let entry = self
            .sessions
            .entry(session_id.clone())
            .or_insert_with(|| SessionTrack {
                epoch: StorageEpoch::default(),
                expected_revision: revision,
                published_revision: None,
            });
        if entry.expected_revision.as_u64() == 0 && revision.as_u64() > 0 {
            entry.epoch = entry.epoch.next();
        }
        entry.expected_revision = revision;
        entry.epoch
    }

    fn release_pending(&mut self, byte_cost: usize) {
        self.pending_jobs = self.pending_jobs.saturating_sub(1);
        self.pending_bytes = self.pending_bytes.saturating_sub(byte_cost);
    }
}

struct ServiceSaveTask {
    storage: Arc<SessionStorage>,
    epoch: StorageEpoch,
    session_id: StorageSessionId,
    revision: StorageRevision,
    record: SessionRecord,
}

fn execute_save(task: ServiceSaveTask) -> PersistenceCompletion {
    let lock_res = task.storage.lock(&task.session_id);
    let lock = match lock_res {
        Ok(l) => l,
        Err(e) => {
            return PersistenceCompletion::Failed {
                epoch: task.epoch,
                session_id: task.session_id,
                error: e,
                durability: Durability::Volatile,
            };
        }
    };
    if task.revision.as_u64() > 1 {
        let prev = StorageRevision::from_u64(task.revision.as_u64().saturating_sub(1));
        if let Err(e) = check_expected_revision(&task.storage, &lock, prev) {
            return PersistenceCompletion::Failed {
                epoch: task.epoch,
                session_id: task.session_id,
                error: e,
                durability: Durability::Volatile,
            };
        }
    }
    match task.storage.save_snapshot(&lock, &task.record) {
        Ok(()) => PersistenceCompletion::SnapshotSaved {
            epoch: task.epoch,
            session_id: task.session_id,
            revision: task.revision,
            durability: Durability::Durable,
        },
        Err(e) => PersistenceCompletion::Failed {
            epoch: task.epoch,
            session_id: task.session_id,
            error: e,
            durability: Durability::Volatile,
        },
    }
}

struct ServiceDeleteTask {
    storage: Arc<SessionStorage>,
    epoch: StorageEpoch,
    session_id: StorageSessionId,
}

fn execute_service_delete(task: ServiceDeleteTask) -> PersistenceCompletion {
    let lock_res = task.storage.lock(&task.session_id);
    let lock = match lock_res {
        Ok(l) => l,
        Err(e) => {
            return PersistenceCompletion::Failed {
                epoch: task.epoch,
                session_id: task.session_id,
                error: e,
                durability: Durability::Volatile,
            };
        }
    };
    match task.storage.delete_session(&lock) {
        Ok(()) => PersistenceCompletion::SessionDeleted {
            epoch: task.epoch,
            session_id: task.session_id,
            durability: Durability::Durable,
        },
        Err(e) => PersistenceCompletion::Failed {
            epoch: task.epoch,
            session_id: task.session_id,
            error: e,
            durability: Durability::Volatile,
        },
    }
}

struct ServiceImportTask {
    storage: Arc<SessionStorage>,
    epoch: StorageEpoch,
    session_id: StorageSessionId,
    candidate: SessionCandidate,
}

fn execute_import(task: ServiceImportTask) -> PersistenceCompletion {
    let lock_res = task.storage.lock(&task.session_id);
    let lock = match lock_res {
        Ok(l) => l,
        Err(e) => {
            return PersistenceCompletion::Failed {
                epoch: task.epoch,
                session_id: task.session_id,
                error: e,
                durability: Durability::Volatile,
            };
        }
    };
    match task.storage.import_candidate(&lock, &task.candidate) {
        Ok(()) => PersistenceCompletion::CandidateImported {
            epoch: task.epoch,
            session_id: task.session_id,
            durability: Durability::Durable,
        },
        Err(e) => PersistenceCompletion::Failed {
            epoch: task.epoch,
            session_id: task.session_id,
            error: e,
            durability: Durability::Volatile,
        },
    }
}

fn check_expected_revision(
    storage: &SessionStorage,
    lock: &SessionLock,
    expected: StorageRevision,
) -> Result<(), CoreError> {
    if let Ok(Some(existing)) = storage.load_snapshot(lock) {
        if expected.as_u64() > 0 && existing.revision() != expected {
            return Err(CoreError::Persistence(PersistenceError::StaleRevision));
        }
    } else if expected.as_u64() > 1 {
        return Err(CoreError::Persistence(PersistenceError::StaleRevision));
    }
    Ok(())
}

/// Target session and storage directory for a persistence operation.
#[derive(Clone, Debug)]
pub struct PersistenceTarget {
    storage_root: StorageLocation,
    session_id: StorageSessionId,
}

impl PersistenceTarget {
    /// Create a new persistence target descriptor.
    pub fn new(storage_root: StorageLocation, session_id: StorageSessionId) -> Self {
        Self {
            storage_root,
            session_id,
        }
    }

    /// Access the storage location.
    pub fn storage_root(&self) -> &StorageLocation {
        &self.storage_root
    }

    /// Access session id.
    pub fn session_id(&self) -> &StorageSessionId {
        &self.session_id
    }
}

/// Save task payload.
#[derive(Debug)]
pub struct SaveTask {
    target: PersistenceTarget,
    expected_revision: StorageRevision,
    record: Box<SessionRecord>,
}

impl SaveTask {
    /// Create a new save task.
    pub fn new(
        target: PersistenceTarget,
        expected_revision: StorageRevision,
        record: Box<SessionRecord>,
    ) -> Self {
        Self {
            target,
            expected_revision,
            record,
        }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let storage = SessionStorage::new(resolve_location(&self.target.storage_root)?)?;
        let lock = storage.lock(&self.target.session_id)?;
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        check_expected_revision(&storage, &lock, self.expected_revision)?;
        storage.save_snapshot(&lock, &self.record)?;
        let rev = self.record.revision();
        Ok(PersistenceOutput::Saved {
            session_id: self.target.session_id,
            revision: rev,
        })
    }
}

/// Load task payload.
#[derive(Debug)]
pub struct LoadTask {
    target: PersistenceTarget,
    expected_revision: Option<StorageRevision>,
}

impl LoadTask {
    /// Create a new load task.
    pub fn new(target: PersistenceTarget, expected_revision: Option<StorageRevision>) -> Self {
        Self {
            target,
            expected_revision,
        }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let storage = SessionStorage::new(resolve_location(&self.target.storage_root)?)?;
        let lock = storage.lock(&self.target.session_id)?;
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let record = storage.load_session(&lock)?;
        if let (Some(rec), Some(exp)) = (&record, self.expected_revision)
            && rec.revision() != exp
        {
            return Err(CoreError::Persistence(PersistenceError::StaleRevision));
        }
        Ok(PersistenceOutput::Loaded {
            session_id: self.target.session_id,
            record: record.map(Box::new),
        })
    }
}

/// List task payload.
#[derive(Debug)]
pub struct ListTask {
    storage_root: StorageLocation,
}

impl ListTask {
    /// Create a new list task.
    pub fn new(storage_root: StorageLocation) -> Self {
        Self { storage_root }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let storage = SessionStorage::new(resolve_location(&self.storage_root)?)?;
        let result = storage.list_sessions()?;
        Ok(PersistenceOutput::Listed(result))
    }
}

/// Delete task payload.
#[derive(Debug)]
pub struct DeleteTask {
    target: PersistenceTarget,
    expected_revision: Option<StorageRevision>,
}

impl DeleteTask {
    /// Create a new delete task.
    pub fn new(target: PersistenceTarget, expected_revision: Option<StorageRevision>) -> Self {
        Self {
            target,
            expected_revision,
        }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let storage = SessionStorage::new(resolve_location(&self.target.storage_root)?)?;
        let lock = storage.lock(&self.target.session_id)?;
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        if let Some(exp) = self.expected_revision {
            check_expected_revision(&storage, &lock, exp)?;
        }
        storage.delete_session(&lock)?;
        Ok(PersistenceOutput::Deleted {
            session_id: self.target.session_id,
        })
    }
}

/// Where an import's session payload comes from.
#[derive(Debug)]
enum ImportSource {
    /// A payload the caller already supplied and the actor migrated.
    Candidate(Box<SessionCandidate>),
    /// A snapshot the worker reads from another storage location.
    Local {
        location: StorageLocation,
        id: StorageSessionId,
        collision: CollisionPolicy,
    },
}

/// Import task payload.
#[derive(Debug)]
pub struct ImportTask {
    storage_root: StorageLocation,
    source: ImportSource,
}

impl ImportTask {
    /// Create a new import task for an already migrated candidate.
    pub fn new(storage_root: StorageLocation, candidate: Box<SessionCandidate>) -> Self {
        Self {
            storage_root,
            source: ImportSource::Candidate(candidate),
        }
    }

    /// Import `id` from `source`, read and migrated on the worker.
    pub fn from_location(
        storage_root: StorageLocation,
        source: StorageLocation,
        target: (StorageSessionId, CollisionPolicy),
    ) -> Self {
        let (id, collision) = target;
        Self {
            storage_root,
            source: ImportSource::Local {
                location: source,
                id,
                collision,
            },
        }
    }

    fn candidate(source: ImportSource) -> Result<Box<SessionCandidate>, CoreError> {
        match source {
            ImportSource::Candidate(candidate) => Ok(candidate),
            ImportSource::Local {
                location,
                id,
                collision,
            } => {
                let payload = read_import_source(&location, &id)?;
                Ok(Box::new(migrate_candidate(&payload, &collision)?))
            }
        }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let candidate = Self::candidate(self.source)?;
        let storage = SessionStorage::new(resolve_location(&self.storage_root)?)?;
        let session_id = candidate.id().clone();
        let lock = storage.lock(&session_id)?;
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        storage.import_candidate(&lock, &candidate)?;
        let rev = candidate.record().revision();
        Ok(PersistenceOutput::Imported {
            session_id,
            revision: rev,
        })
    }
}

/// Prune task payload.
#[derive(Debug)]
pub struct PruneTask {
    storage_root: StorageLocation,
    policy: SessionRetentionPolicy,
    active_sessions: BTreeSet<StorageSessionId>,
}

impl PruneTask {
    /// Create a new prune task.
    pub fn new(
        storage_root: StorageLocation,
        policy: SessionRetentionPolicy,
        active_sessions: BTreeSet<StorageSessionId>,
    ) -> Self {
        Self {
            storage_root,
            policy,
            active_sessions,
        }
    }

    fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        let storage = SessionStorage::new(resolve_location(&self.storage_root)?)?;
        let report = storage.prune_sessions(&self.policy, &self.active_sessions)?;
        Ok(PersistenceOutput::Pruned(report))
    }
}

/// Background work payload for session persistence operations.
#[derive(Debug)]
pub enum PersistenceWork {
    /// Save a snapshot.
    Save(SaveTask),
    /// Load and recover a session.
    Load(LoadTask),
    /// List all session summaries in storage.
    List(ListTask),
    /// Delete a session snapshot and journal.
    Delete(DeleteTask),
    /// Import a session candidate.
    Import(ImportTask),
    /// Prune sessions and clean temp files according to retention policy.
    Prune(PruneTask),
}

impl PersistenceWork {
    /// Execute persistence operation on a blocking worker.
    pub fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<PersistenceOutput, CoreError> {
        match self {
            Self::Save(task) => task.execute(cancel, deadline),
            Self::Load(task) => task.execute(cancel, deadline),
            Self::List(task) => task.execute(cancel, deadline),
            Self::Delete(task) => task.execute(cancel, deadline),
            Self::Import(task) => task.execute(cancel, deadline),
            Self::Prune(task) => task.execute(cancel, deadline),
        }
    }
}

/// Completion output from a background persistence task.
#[derive(Debug)]
pub enum PersistenceOutput {
    /// Snapshot was committed.
    Saved {
        /// Session identifier.
        session_id: StorageSessionId,
        /// Saved revision.
        revision: StorageRevision,
    },
    /// Session was loaded/recovered.
    Loaded {
        /// Session identifier.
        session_id: StorageSessionId,
        /// Loaded record.
        record: Option<Box<SessionRecord>>,
    },
    /// Sessions were listed.
    Listed(SessionListResult),
    /// Session was deleted.
    Deleted {
        /// Session identifier.
        session_id: StorageSessionId,
    },
    /// Candidate was imported.
    Imported {
        /// Session identifier.
        session_id: StorageSessionId,
        /// Imported revision.
        revision: StorageRevision,
    },
    /// Storage retention pruning was executed.
    Pruned(RetentionReport),
}

impl PersistenceOutput {
    /// Serialize output into JSON-RPC response format.
    pub fn into_value(self) -> Result<serde_json::Value, CoreError> {
        match self {
            Self::Saved {
                session_id,
                revision,
            } => Ok(serde_json::json!({
                "status": "ok",
                "session_id": session_id.as_str(),
                "revision": revision.as_u64(),
            })),
            Self::Loaded { session_id, record } => Ok(serde_json::json!({
                "status": "ok",
                "session_id": session_id.as_str(),
                "record": record,
            })),
            Self::Listed(result) => Ok(serde_json::json!({
                "status": "ok",
                "sessions": result.summaries(),
                "truncated": matches!(result.truncation(), ListTruncation::Truncated),
            })),
            Self::Deleted { session_id } => Ok(serde_json::json!({
                "status": "ok",
                "deleted": true,
                "session_id": session_id.as_str(),
            })),
            Self::Imported {
                session_id,
                revision,
            } => Ok(serde_json::json!({
                "status": "ok",
                "session_id": session_id.as_str(),
                "revision": revision.as_u64(),
            })),
            Self::Pruned(report) => Ok(serde_json::json!({
                "status": "ok",
                "pruned_count": report.pruned_count().as_usize(),
                "pruned_bytes": report.pruned_bytes().as_u64(),
                "retained_count": report.retained_count().as_usize(),
                "cleaned_temp_files": report.cleaned_temp_files().as_usize(),
            })),
        }
    }
}
