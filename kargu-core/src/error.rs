//! Typed domain and service failures. Decisions never depend on message text.

/// Cross-service failure taxonomy. Display deliberately excludes command/input data.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
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
    /// Run or operation deadline expired.
    #[error("deadline exceeded")]
    Deadline,
    /// Canonical tool or executor capability is absent.
    #[error("tool unavailable")]
    Unavailable,
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
    /// Tool invocation budget, expressed in tool steps rather than tokens.
    #[error("tool-call budget exhausted")]
    BudgetExceeded {
        /// Maximum calls admitted by this run.
        limit: crate::domain::ToolCallLimit,
        /// Calls already admitted, in the matching unit.
        spent: crate::domain::StepCount,
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
