//! Canonical model metadata boundaries, independent of editor and transport IO.

pub mod catalog;
mod numeric;
pub use numeric::{ContextCapacity, InputTokenRate, NumericError, OutputCapacity, OutputTokenRate};
