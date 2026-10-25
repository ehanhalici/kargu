//! Deterministic retry/circuit policy, composed by a single-writer owner.
//! This module alone does not enable hidden retries inside HTTP execution.
//!
//! A circuit outcome right cannot be recorded twice:
//! ```compile_fail
//! use kargu_core::api::resilience::{Circuit, CircuitPolicy, CircuitOutcome};
//! use tokio::time::Instant;
//! fn cannot_record_twice() -> Result<(), Box<dyn std::error::Error>> {
//! let mut circuit = Circuit::new(CircuitPolicy::default());
//! let lease = circuit.acquire(Instant::now())?;
//! circuit.record(lease, CircuitOutcome::Neutral, Instant::now())?;
//! circuit.record(lease, CircuitOutcome::Neutral, Instant::now())?;
//! Ok(())
//! }
//! ```

mod breaker;
mod domain;
mod retry;
pub use breaker::{Circuit, CircuitLease, CircuitOutcome, CircuitPhase, CircuitRefusal};
pub use domain::{CircuitPolicy, Publication, RetryDelay};
pub use retry::{RetryDecision, RetryPolicy, RetryStop};
