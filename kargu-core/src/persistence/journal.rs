//! Bounded append-only journal engine, sequence verification, and checkpoint commit order.
//!
//! Enforces:
//! - Monotonic sequence progression and SHA-256 digest chaining across envelopes.
//! - Checkpoint commit order: journal checkpoint is fsynced before snapshot is published.
//! - Immediate poisoning: any partial write or fsync failure closes the writer permanently.
//! - Read-only recovery capable of reconstructing the last durable checkpoint even if snapshot is missing.
//! - Bounded file size and symlink rejection.

use crate::{
    constants::limits,
    error::CoreError,
    persistence::{
        domain::{
            PersistenceError, SessionMessage, SessionRecord, StorageSequence, StorageSessionId,
        },
        recovery::{TailTruncation, replay_journal_file},
        storage::{SessionLock, SessionStorage},
    },
};
use nix::{
    fcntl::{OFlag, open},
    sys::stat::Mode,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Write, os::unix::fs::MetadataExt};

fn os_err(error: nix::errno::Errno) -> CoreError {
    std::io::Error::from(error).into()
}

/// SHA-256 integrity hash chaining journal records.
#[derive(Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
pub struct JournalRecordDigest([u8; 32]);

impl JournalRecordDigest {
    /// Genesis digest preceding the first journal entry.
    pub const GENESIS: Self = Self([0u8; 32]);

    /// Return raw byte array slice.
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for JournalRecordDigest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Digest({:x?})", &self.0[..4])
    }
}

/// Discrete journal payload.
#[derive(Clone, Serialize, Deserialize)]
pub enum JournalEntry {
    /// Full session checkpoint.
    Checkpoint(Box<SessionRecord>),
    /// Incremental turn message.
    Delta(SessionMessage),
}

/// Sequenced and hash-chained journal envelope.
#[derive(Clone, Serialize, Deserialize)]
pub struct JournalEnvelope {
    sequence: StorageSequence,
    previous_digest: JournalRecordDigest,
    digest: JournalRecordDigest,
    entry: JournalEntry,
}

impl JournalEnvelope {
    /// Sequence counter of this envelope.
    pub fn sequence(&self) -> StorageSequence {
        self.sequence
    }

    /// Hash digest of this envelope.
    pub fn digest(&self) -> JournalRecordDigest {
        self.digest
    }

    /// Preceding digest chained to this envelope.
    pub fn previous_digest(&self) -> JournalRecordDigest {
        self.previous_digest
    }

    /// Contained journal entry.
    pub fn entry(&self) -> &JournalEntry {
        &self.entry
    }
}

/// Operational state of a journal writer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WriterState {
    /// Healthy and accepting appends.
    Active,
    /// Incurred a write/sync failure and permanently closed to further appends.
    Poisoned,
}

/// Sequenced, append-only journal writer.
pub struct SessionJournalWriter {
    file: File,
    session_id: StorageSessionId,
    _lock: SessionLock,
    sequence: StorageSequence,
    last_digest: JournalRecordDigest,
    written_bytes: usize,
    state: WriterState,
}

impl SessionJournalWriter {
    /// Open or create the journal for `lock.id()`. Replays existing entries to verify integrity.
    pub fn open(storage: &SessionStorage, lock: SessionLock) -> Result<Self, CoreError> {
        let path = storage
            .root()
            .path()
            .join(format!("{}.journal", lock.id().as_str()));
        let raw = open(
            &path,
            OFlag::O_RDWR | OFlag::O_CREAT | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
            Mode::from_bits_truncate(0o600),
        )
        .map_err(os_err)?;
        let file = File::from(raw);
        validate_file_meta(&file)?;
        let outcome = replay_journal_file(&path, lock.id(), TailTruncation::AllowTruncate)?;
        Ok(Self {
            file,
            session_id: lock.id().clone(),
            _lock: lock,
            sequence: outcome.sequence(),
            last_digest: outcome.digest(),
            written_bytes: outcome.valid_bytes().as_usize(),
            state: WriterState::Active,
        })
    }

    /// Current operational state of the writer.
    pub fn state(&self) -> WriterState {
        self.state
    }

    /// Target session identifier.
    pub fn session_id(&self) -> &StorageSessionId {
        &self.session_id
    }

    /// Current sequence counter.
    pub fn sequence(&self) -> StorageSequence {
        self.sequence
    }

    /// Append a full checkpoint to the journal.
    pub fn append_checkpoint(
        &mut self,
        record: &SessionRecord,
    ) -> Result<JournalRecordDigest, CoreError> {
        self.ensure_active()?;
        let entry = JournalEntry::Checkpoint(Box::new(record.clone()));
        self.append_entry(entry)
    }

    /// Append an incremental message delta to the journal.
    pub fn append_delta(
        &mut self,
        message: &SessionMessage,
    ) -> Result<JournalRecordDigest, CoreError> {
        self.ensure_active()?;
        let entry = JournalEntry::Delta(message.clone());
        self.append_entry(entry)
    }

    /// Atomically commit checkpoint order: journal fsync first, then snapshot publish.
    pub fn commit_snapshot(
        &mut self,
        storage: &SessionStorage,
        record: &SessionRecord,
    ) -> Result<(), CoreError> {
        self.ensure_active()?;
        self.append_checkpoint(record)?;
        storage.save_snapshot(&self._lock, record)
    }

    fn ensure_active(&self) -> Result<(), CoreError> {
        if self.state == WriterState::Poisoned {
            Err(CoreError::Rejected)
        } else {
            Ok(())
        }
    }

    fn append_entry(&mut self, entry: JournalEntry) -> Result<JournalRecordDigest, CoreError> {
        let next_seq = self.sequence.next()?;
        let digest = calculate_digest(&self.last_digest, next_seq, &entry)?;
        let envelope = JournalEnvelope {
            sequence: next_seq,
            previous_digest: self.last_digest,
            digest,
            entry,
        };
        let mut line = serde_json::to_vec(&envelope)
            .map_err(|_| CoreError::from(PersistenceError::Validation("envelope encode error")))?;
        line.push(b'\n');
        let next_total = self.written_bytes.saturating_add(line.len());
        if next_total > limits::SESSION_MAX_FILE_BYTES {
            return Err(CoreError::Limit);
        }
        self.write_and_sync(&line, &envelope)
    }

    fn write_and_sync(
        &mut self,
        data: &[u8],
        envelope: &JournalEnvelope,
    ) -> Result<JournalRecordDigest, CoreError> {
        if let Err(e) = self.file.write_all(data) {
            self.state = WriterState::Poisoned;
            return Err(e.into());
        }
        if let Err(e) = self.file.sync_all() {
            self.state = WriterState::Poisoned;
            return Err(e.into());
        }
        self.sequence = envelope.sequence;
        self.last_digest = envelope.digest;
        self.written_bytes = self.written_bytes.saturating_add(data.len());
        Ok(envelope.digest)
    }
}

fn validate_file_meta(file: &File) -> Result<(), CoreError> {
    let meta = file.metadata()?;
    if meta.uid() != nix::unistd::geteuid().as_raw() {
        return Err(CoreError::StaleOwner);
    }
    if meta.mode() & 0o7777 != 0o600 {
        return Err(CoreError::Rejected);
    }
    Ok(())
}

/// Compute deterministic SHA-256 integrity hash chaining journal records.
pub fn calculate_digest(
    prev: &JournalRecordDigest,
    seq: StorageSequence,
    entry: &JournalEntry,
) -> Result<JournalRecordDigest, CoreError> {
    let mut hasher = Sha256::new();
    hasher.update(prev.as_bytes());
    hasher.update(seq.as_u64().to_le_bytes());
    let entry_bytes = serde_json::to_vec(entry)
        .map_err(|_| CoreError::from(PersistenceError::Validation("entry hash error")))?;
    hasher.update(&entry_bytes);
    let output = hasher.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&output);
    Ok(JournalRecordDigest(arr))
}

/// Read a journal file and recover the last durable checkpoint if one exists.
pub fn recover_last_checkpoint(
    storage: &SessionStorage,
    session_id: &StorageSessionId,
) -> Result<Option<SessionRecord>, CoreError> {
    let path = storage
        .root()
        .path()
        .join(format!("{}.journal", session_id.as_str()));
    if !path.exists() {
        return Ok(None);
    }
    let outcome = replay_journal_file(&path, session_id, TailTruncation::AllowTruncate)?;
    Ok(outcome.into_record())
}
