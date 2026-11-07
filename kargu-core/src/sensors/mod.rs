//! Typed live-editor observations. Freshness requires runtime evidence from the editor.
//!
//! Filesystem metadata and elapsed waiting time cannot establish that a diagnostic
//! publication or debugger reply belongs to the captured live resource.

pub mod coordinates;
pub mod debugger;
pub mod diagnostics;
pub(crate) mod mention_rpc;
pub mod mentions;
pub mod symbols;
pub mod types;
