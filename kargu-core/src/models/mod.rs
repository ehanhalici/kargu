//! Canonical model metadata boundaries, independent of editor and transport IO.

mod numeric;
pub use numeric::{ContextCapacity, InputTokenRate, NumericError, OutputCapacity, OutputTokenRate};
