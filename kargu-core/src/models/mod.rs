//! Canonical model metadata boundaries, independent of editor and transport IO.

pub mod catalog;
pub mod metadata;
mod numeric;
pub use numeric::{
    CacheReadTokenRate, CacheWriteTokenRate, ContextCapacity, InputTokenRate, NumericError,
    OutputCapacity, OutputTokenRate,
};
