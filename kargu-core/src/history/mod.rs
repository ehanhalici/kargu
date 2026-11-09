//! Actor-owned conversation history and exact tool-call/result accounting.
//!
//! Provider-specific fields are retained at the message serialization boundary.
//! Domain transitions use parsed roles and call identities, never text prefixes.

mod compact;
mod message;
mod presentation;
mod rpc;
mod store;
mod types;
mod upload;

pub use crate::domain::ProviderCallId;
pub use compact::{
    CompactKeep, CompactThreshold, PreservedTail, SummaryCandidate, SummaryText, TailHash,
    build_compacted_history, compaction_prompt_message,
};
pub use message::{Message, ProviderCall, Role};
pub(crate) use rpc::fault;
pub use store::{History, PendingCall, StoredMessage};
pub use types::{HistoryBytes, HistoryRevision};
pub(crate) use upload::{HistoryImports, HistoryWork};

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
