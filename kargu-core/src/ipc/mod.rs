//! Bounded JSON-RPC framing, correlation and transport.

mod api;
mod execution;
pub mod pending;
pub mod protocol;
mod read_tools;
mod transport;

pub use transport::serve;

/// Control queue's aggregate retained byte limit.
pub use crate::constants::limits::CONTROL_BYTES;
/// Control queue's message limit.
pub use crate::constants::limits::CONTROL_CAPACITY;
/// Absolute inbound and outbound frame limit, excluding LF.
pub use crate::constants::limits::MAX_FRAME_BYTES;
/// Maximum number of outstanding reverse calls.
pub use crate::constants::limits::MAX_PENDING;
