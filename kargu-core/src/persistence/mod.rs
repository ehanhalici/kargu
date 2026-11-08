//! Persistent session storage, journal, and schema migration engine.

pub mod domain;
pub mod journal;
pub mod migration;
pub mod recovery;
pub mod repair;
pub mod storage;
pub mod worker;

pub use domain::{
    CleanedTempCount, JournalByteOffset, ListTruncation, MaxSessionAge, MaxSessionBytes,
    MaxSessionCount, MessageContent, MessageRole, PersistedToolArguments, PersistedToolCall,
    PersistedToolCallId, PersistedToolFunction, PersistedToolKind, PersistedToolName,
    PersistenceError, PrunedByteCount, PrunedSessionCount, ReasoningContent, RetainedSessionCount,
    RetentionReport, SessionEffort, SessionListResult, SessionMessage, SessionMessageCount,
    SessionMode, SessionModel, SessionProjectName, SessionProvider, SessionRecord,
    SessionRepairCount, SessionRetentionPolicy, SessionSummary, SessionTimestamp, SessionTitle,
    SessionTranscript, StorageRevision, StorageRoot, StorageSchemaVersion, StorageSequence,
    StorageSessionId,
};

pub use journal::{
    JournalEntry, JournalEnvelope, JournalRecordDigest, SessionJournalWriter, WriterState,
    calculate_digest, recover_last_checkpoint,
};

pub use migration::{
    CollisionPolicy, RawSessionPayload, SessionCandidate, SessionSourceFormat, migrate_candidate,
};

pub use recovery::{
    JournalReplayOutcome, TailTruncation, recover_session_view, replay_journal_file,
};

pub use repair::repair_protocol;

pub use storage::{SessionLock, SessionStorage};

pub use worker::{
    CompletionVerdict, DeleteTask, Durability, ImportTask, ListTask, LoadTask,
    PersistenceCompletion, PersistenceOutput, PersistenceService, PersistenceTarget,
    PersistenceWork, PruneTask, SaveRequest, SaveTask, StorageEpoch,
};

#[cfg(test)]
mod tests;
