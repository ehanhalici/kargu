//! Kargu's opt-in Rust host and typed execution services.
//! The stdio capability surface remains lifecycle-only while execution adapters migrate.

#![forbid(unsafe_code)]

pub mod application;
pub mod constants;
pub mod domain;
pub mod error;
pub mod host;
pub mod ipc;
pub mod process;
pub mod security;

/// Package version advertised during negotiation.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
