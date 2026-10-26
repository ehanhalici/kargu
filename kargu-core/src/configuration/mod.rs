//! Readonly native configuration parsing and IO; publication remains an owner port.
//!
//! Raw source never gains a generic serialization or diagnostic surface.
//! ```compile_fail
//! use kargu_core::configuration::ConfigurationSource;
//! fn serialize(source: &ConfigurationSource) {
//!     let _ = serde_json::to_string(source);
//! }
//! ```
//! ```compile_fail
//! use kargu_core::configuration::ConfigurationSource;
//! fn diagnose(source: &ConfigurationSource) {
//!     let _ = format!("{source:?}");
//! }
//! ```

mod document;
mod domain;
pub mod read;
pub use domain::{
    ConfigurationError, ConfigurationSource, MAX_SOURCE_BYTES, RefreshGeneration, SourceLine,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// One immutable editor intent. No environment or filesystem lookup is implicit.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ParseInput {
    source: ConfigurationSource,
    generation: RefreshGeneration,
}
impl ParseInput {
    /// Consume captured text into an explicit private editor handoff or safe error.
    pub fn resolve(self) -> Value {
        let parsed = document::Document::parse(&self.source.0);
        match parsed {
            Ok(config) => {
                let result = json!({"status":"ok","generation":self.generation,
                    "digest":format!("{:x}", Sha256::digest(self.source.0.as_bytes())), "config":config});
                if zeroize::Zeroizing::new(result.to_string()).len() > 512 * 1024 {
                    json!({"status":"limit","generation":self.generation})
                } else {
                    result
                }
            }
            Err(ConfigurationError::Invalid { line }) => {
                json!({"status":"invalid","generation":self.generation,"line":line})
            }
            Err(ConfigurationError::Limit) => {
                json!({"status":"limit","generation":self.generation})
            }
        }
    }
}
