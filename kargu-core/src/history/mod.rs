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

pub use crate::error::HistoryError;
