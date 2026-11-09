//! Native proposal, review and transaction domain. Editor writes require a later grant.
//!
//! Text/framing preparation has no filesystem or editor side effects. A parsed
//! patch or a content hash is evidence, never authority to apply an editor edit.

pub use crate::intent;
pub mod journal;
pub mod patch;
pub(crate) mod prepare;
pub mod proposal;
pub mod review;
pub use crate::intent::types;

pub use crate::error::EditError;
