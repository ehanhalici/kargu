//! Crash-consistent journal replay, tail truncation, and session recovery.
//!
//! Enforces:
//! - Safe truncation ONLY of incomplete trailing records (torn writes missing terminal newline).
//! - Strict error rejection of complete corrupted records, checksum mismatches, or sequence gaps
//!   WITHOUT modifying or deleting files.
//! - Strict session ID matching across snapshot files, journal checkpoints, and requested ID.
//! - Bounded domain invariants on the reconstructed session candidate.
//! - Unified committed recovery view shared between load and listing queries.

use crate::{
    error::CoreError,
    persistence::{
        domain::{
            JournalByteOffset, PersistenceError, SessionRecord, StorageSequence, StorageSessionId,
        },
        journal::{JournalEntry, JournalEnvelope, JournalRecordDigest, calculate_digest},
        storage::SessionStorage,
    },
};
use nix::{
    fcntl::{OFlag, open},
    sys::stat::Mode,
};
use std::{
    fs::File,
    io::{BufRead, BufReader, Read},
    os::unix::fs::MetadataExt,
    path::Path,
};

fn os_err(error: nix::errno::Errno) -> CoreError {
    std::io::Error::from(error).into()
}

/// Policy for handling torn trailing journal records.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TailTruncation {
    /// Safely truncate incomplete trailing records missing terminal newline.
    AllowTruncate,
    /// Read-only inspection; ignore incomplete trailing record without modifying file.
    ReadOnly,
}

/// Result of replaying and verifying a journal file.
#[derive(Clone, Debug)]
pub struct JournalReplayOutcome {
    sequence: StorageSequence,
    digest: JournalRecordDigest,
    valid_bytes: usize,
    record: Option<SessionRecord>,
}

impl JournalReplayOutcome {
    /// Sequence counter of the last valid journal record.
    pub fn sequence(&self) -> StorageSequence {
        self.sequence
    }

    /// Integrity digest of the last valid journal record.
    pub fn digest(&self) -> JournalRecordDigest {
        self.digest
    }

    /// Cumulative valid byte length.
    pub fn valid_bytes(&self) -> JournalByteOffset {
        JournalByteOffset::from_usize(self.valid_bytes)
    }

    /// Borrow the reconstructed session record, if any checkpoint was recovered.
    pub fn record(&self) -> Option<&SessionRecord> {
        self.record.as_ref()
    }

    /// Consume outcome and return reconstructed session record.
    pub fn into_record(self) -> Option<SessionRecord> {
        self.record
    }

    fn from_state(state: ReplayState) -> Self {
        Self {
            sequence: StorageSequence::from_u64(state.sequence),
            digest: state.digest,
            valid_bytes: state.valid_bytes,
            record: state.record,
        }
    }
}

struct ReplayState {
    sequence: u64,
    digest: JournalRecordDigest,
    valid_bytes: usize,
    record: Option<SessionRecord>,
}

impl ReplayState {
    fn new() -> Self {
        Self {
            sequence: 0,
            digest: JournalRecordDigest::GENESIS,
            valid_bytes: 0,
            record: None,
        }
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

fn open_journal_file(path: &Path, policy: TailTruncation) -> Result<File, CoreError> {
    let flags = match policy {
        TailTruncation::AllowTruncate => OFlag::O_RDWR | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
        TailTruncation::ReadOnly => OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
    };
    let raw = open(path, flags, Mode::from_bits_truncate(0o600)).map_err(os_err)?;
    let file = File::from(raw);
    validate_file_meta(&file)?;
    Ok(file)
}

fn parse_and_validate_line(
    line: &[u8],
    state: &mut ReplayState,
    id: &StorageSessionId,
) -> Result<(), CoreError> {
    let envelope: JournalEnvelope = serde_json::from_slice(line)
        .map_err(|_| CoreError::from(PersistenceError::CorruptedRecord("invalid json envelope")))?;
    let expected_seq = state.sequence.saturating_add(1);
    if envelope.sequence().as_u64() != expected_seq {
        return Err(CoreError::from(PersistenceError::SequenceGap));
    }
    if envelope.previous_digest() != state.digest {
        return Err(CoreError::from(PersistenceError::ChecksumMismatch));
    }
    let computed = calculate_digest(&state.digest, envelope.sequence(), envelope.entry())?;
    if computed != envelope.digest() {
        return Err(CoreError::from(PersistenceError::ChecksumMismatch));
    }
    handle_entry(envelope.entry(), state, id)?;
    state.sequence = expected_seq;
    state.digest = envelope.digest();
    Ok(())
}

fn handle_entry(
    entry: &JournalEntry,
    state: &mut ReplayState,
    id: &StorageSessionId,
) -> Result<(), CoreError> {
    match entry {
        JournalEntry::Checkpoint(rec) => {
            if rec.id() != id {
                return Err(CoreError::Rejected);
            }
            rec.validate_record()?;
            state.record = Some((**rec).clone());
            Ok(())
        }
        JournalEntry::Delta(msg) => {
            let rec = state.record.as_mut().ok_or_else(|| {
                CoreError::from(PersistenceError::Validation("delta before checkpoint"))
            })?;
            rec.append_message(msg.clone())?;
            Ok(())
        }
    }
}

fn handle_torn_tail(file: &mut File, offset: u64, policy: TailTruncation) -> Result<(), CoreError> {
    if policy == TailTruncation::AllowTruncate {
        file.set_len(offset)?;
        file.sync_all()?;
    }
    Ok(())
}

/// Replay and verify a journal file, safely truncating incomplete trailing records if permitted.
pub fn replay_journal_file(
    path: &Path,
    id: &StorageSessionId,
    policy: TailTruncation,
) -> Result<JournalReplayOutcome, CoreError> {
    let mut file = open_journal_file(path, policy)?;
    let mut reader = BufReader::new(&mut file);
    let mut state = ReplayState::new();
    let mut line_buf = Vec::new();
    let mut torn_tail_offset: Option<u64> = None;
    loop {
        line_buf.clear();
        let bytes = reader.read_until(b'\n', &mut line_buf)?;
        if bytes == 0 {
            break;
        }
        if line_buf.last() != Some(&b'\n') {
            torn_tail_offset = Some(state.valid_bytes as u64);
            break;
        }
        parse_and_validate_line(&line_buf, &mut state, id)?;
        state.valid_bytes = state.valid_bytes.saturating_add(bytes);
    }
    drop(reader);
    if let Some(offset) = torn_tail_offset {
        handle_torn_tail(&mut file, offset, policy)?;
    }
    Ok(JournalReplayOutcome::from_state(state))
}

fn load_snapshot_view(
    path: &Path,
    expected_id: &StorageSessionId,
) -> Result<Option<SessionRecord>, CoreError> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = open(
        path,
        OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
        Mode::empty(),
    )
    .map_err(os_err)?;
    let file = File::from(raw);
    validate_file_meta(&file)?;
    let content = read_bounded_file(file)?;
    let record = SessionRecord::try_from(content.as_str())?;
    if record.id() != expected_id {
        return Err(CoreError::Rejected);
    }
    record.validate_record()?;
    Ok(Some(record))
}

fn read_bounded_file(mut file: File) -> Result<String, CoreError> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = file.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(chunk.get(..n).ok_or(CoreError::Limit)?);
        if buf.len() > crate::constants::limits::SESSION_MAX_FILE_BYTES {
            return Err(CoreError::Limit);
        }
    }
    String::from_utf8(buf)
        .map_err(|_| CoreError::from(PersistenceError::Validation("invalid utf-8")))
}

/// Unified committed session recovery view shared between load and list operations.
pub fn recover_session_view(
    storage: &SessionStorage,
    id: &StorageSessionId,
    policy: TailTruncation,
) -> Result<Option<SessionRecord>, CoreError> {
    let journal_path = storage
        .root()
        .path()
        .join(format!("{}.journal", id.as_str()));
    let snapshot_path = storage.root().session_file(id)?;
    let mut maybe_record = None;
    if journal_path.exists() {
        let outcome = replay_journal_file(&journal_path, id, policy)?;
        if outcome.record().is_some() {
            maybe_record = outcome.into_record();
        }
    }
    if maybe_record.is_none() {
        maybe_record = load_snapshot_view(&snapshot_path, id)?;
    }
    if let Some(mut rec) = maybe_record {
        crate::persistence::repair::repair_protocol(&mut rec)?;
        Ok(Some(rec))
    } else {
        Ok(None)
    }
}
