//! Typed domain and service failures. Decisions never depend on message text.
//!
//! The whole failure taxonomy lives here, below every module that reports it,
//! so no module error type pulls the taxonomy upward.

/// Cross-service failure taxonomy. Display deliberately excludes command/input data.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    /// Canonical conversation protocol or bounded history-store failure.
    #[error(transparent)]
    History(#[from] HistoryError),
    /// Closed edit preparation/review failure, without source text.
    #[error(transparent)]
    Edit(#[from] EditError),
    /// Session persistence, schema or storage failure.
    #[error(transparent)]
    Persistence(#[from] PersistenceError),
    /// A DTO failed to produce a valid domain value.
    #[error("invalid domain value: {field}")]
    InvalidValue {
        /// Semantic field, never caller-provided text.
        field: &'static str,
    },
    /// A checked counter or value overflowed.
    #[error("arithmetic overflow")]
    ArithmeticOverflow,
    /// A successful process produced malformed/incomplete structured tool output.
    #[error("invalid structured tool output")]
    InvalidToolOutput,
    /// Application already owns an active or draining run.
    #[error("application busy")]
    Busy,
    /// A foreign, obsolete or released owner attempted an operation.
    #[error("stale or foreign owner")]
    StaleOwner,
    /// Publication and execution rights were revoked.
    #[error("operation cancelled")]
    Cancelled,
    /// Queued stdin may already have reached the child; cancellation cannot undo it.
    #[error("stdin delivery unconfirmed; do not replay automatically")]
    InputOutcomeUnknown,
    /// A Git write was issued; cancellation/transport failure cannot undo effects.
    #[error("Git mutation outcome unconfirmed; do not replay automatically")]
    MutationOutcomeUnknown,
    /// Run or operation deadline expired.
    #[error("deadline exceeded")]
    Deadline,
    /// Canonical tool or executor capability is absent.
    #[error("tool unavailable")]
    Unavailable,
    /// The editor's credential source quiesced without a usable key.
    #[error("credential unavailable")]
    CredentialUnavailable,
    /// Current mode or policy forbids the action.
    #[error("permission rejected")]
    Rejected,
    /// Approval expired without granting authority.
    #[error("approval expired")]
    ApprovalExpired,
    /// Approval is unknown, consumed or revoked.
    #[error("approval unavailable or replayed")]
    ApprovalUnavailable,
    /// Captured filesystem identity no longer matches.
    #[error("workspace changed")]
    WorkspaceChanged,
    /// Captured configuration file identity or content revision no longer matches.
    #[error("configuration file changed")]
    ConfigurationChanged,
    /// Tool invocation budget, expressed in tool steps rather than tokens.
    #[error("tool-call budget exhausted")]
    BudgetExceeded {
        /// Maximum calls admitted by this run.
        limit: super::ToolCallLimit,
        /// Calls already admitted, in the matching unit.
        spent: super::StepCount,
    },
    /// A bounded queue or job table is full.
    #[error("resource limit reached")]
    Limit,
    /// Caller already collected the terminal result.
    #[error("operation already completed")]
    AlreadyCompleted,
    /// An OS operation failed; its details are never logged by default.
    #[error("operating system operation failed")]
    Io(#[from] std::io::Error),
    /// Resource cleanup could not be proven complete.
    #[error("resource cleanup failed")]
    CleanupFailed,
}

/// Payload-free conversation protocol failures.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum HistoryError {
    /// Invalid role, content, arguments or message shape.
    #[error("invalid history message")]
    InvalidMessage,
    /// An already committed provider call identity cannot be reused.
    #[error("duplicate tool call identity")]
    DuplicateCall,
    /// A result did not answer a committed pending call.
    #[error("orphan tool result")]
    OrphanResult,
    /// A real or synthetic result already consumed this call.
    #[error("tool call already has a result")]
    DuplicateResult,
    /// A new model/user turn cannot cross an incomplete tool batch.
    #[error("pending tool results require settlement")]
    PendingCalls,
    /// A byte, message, call or reservation capacity was exceeded.
    #[error("history capacity exceeded")]
    Limit,
    /// The supplied snapshot revision has been superseded.
    #[error("stale history revision")]
    StaleRevision,
    /// A monotonic sequence exhausted its representation.
    #[error("history counter overflow")]
    Overflow,
}

/// Closed edit-domain failures. Display never includes source text or filenames.
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum EditError {
    /// The installed Git refused the isolated patch or did not complete safely.
    #[error("isolated patch preparation failed")]
    PatchFailed,
    /// The requested existing target is absent.
    #[error("edit target does not exist")]
    MissingTarget,
    /// Live or filesystem source evidence changed before preparation.
    #[error("edit source conflict")]
    Conflict,
    /// A bounded content, count or collection exceeded its limit.
    #[error("edit resource limit exceeded")]
    Limit,
    /// A model target is empty, absolute, reserved or traverses a parent.
    #[error("invalid edit path")]
    InvalidPath,
    /// Text/framing does not follow the supported Unified Diff grammar.
    #[error("invalid unified patch")]
    InvalidPatch,
    /// Binary, rename/copy, executable modes and legacy directives are absent.
    #[error("unsupported patch operation")]
    UnsupportedPatch,
    /// A replace or zero-context deletion has no literal match.
    #[error("edit context does not match")]
    MissingMatch,
    /// A replace or zero-context deletion lacks unique context.
    #[error("edit context is ambiguous")]
    AmbiguousMatch,
    /// A content hash or coordinate failed its closed wire boundary.
    #[error("invalid edit evidence")]
    InvalidEvidence,
}

/// Failures encountered during session validation, storage path resolution, or schema conversion.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum PersistenceError {
    /// The session identifier was empty or contained illegal characters / path traversal.
    #[error("invalid session identifier: {0}")]
    InvalidId(&'static str),
    /// The resolved session file escapes the storage root boundary.
    #[error("session path escapes storage root")]
    PathEscape,
    /// The session schema version is unsupported.
    #[error("unsupported session schema version: {0}")]
    UnsupportedVersion(u32),
    /// A required field was invalid or missing.
    #[error("session record validation failed: {0}")]
    Validation(&'static str),
    /// Tree nesting depth exceeded maximum permitted limit.
    #[error("session structure exceeded depth limit")]
    DepthLimitExceeded,
    /// Node count exceeded maximum permitted limit.
    #[error("session exceeded node limit")]
    NodeLimitExceeded,
    /// Serialized file size exceeded maximum byte limit.
    #[error("session file exceeded size limit")]
    SizeLimitExceeded,
    /// Number of messages exceeded maximum permitted limit.
    #[error("session messages exceeded count limit")]
    MessageLimitExceeded,
    /// Session identifier collision when importing or creating.
    #[error("session identifier collision")]
    Collision,
    /// Checksum verification failure in journal record.
    #[error("journal checksum mismatch")]
    ChecksumMismatch,
    /// Non-contiguous sequence jump in journal record.
    #[error("journal sequence gap")]
    SequenceGap,
    /// Corrupt journal envelope line.
    #[error("corrupt journal line: {0}")]
    CorruptedRecord(&'static str),
    /// Expected session revision does not match stored revision.
    #[error("stale session revision")]
    StaleRevision,
}
