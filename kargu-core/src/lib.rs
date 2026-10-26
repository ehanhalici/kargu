//! Kargu's opt-in Rust host and typed execution services.
//! Stdio exposes lifecycle, bounded reads and explicitly approved command execution.

#![forbid(unsafe_code)]
#![cfg_attr(not(test), deny(clippy::indexing_slicing))]

pub mod api;
pub mod application;
pub mod configuration;
pub mod constants;
pub mod domain;
pub mod error;
pub mod ipc;
pub mod models;
pub mod process;
pub mod providers;
pub mod security;
pub mod workspace;

/// Package version advertised during negotiation.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
