use super::HistoryError;
use crate::constants::limits;
use serde::{Deserialize, Serialize};

/// Monotonic committed history revision. Neither message counts nor ticks are revisions.
#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct HistoryRevision(u64);
impl HistoryRevision {
    /// Current integer for a wire snapshot or exact revision comparison.
    pub fn get(self) -> u64 {
        self.0
    }
    pub(super) fn next(self) -> Result<Self, HistoryError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(HistoryError::Overflow)
    }
}

/// Accounted serialized history bytes, including pending-result reservations.
#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Serialize)]
pub struct HistoryBytes(usize);
impl TryFrom<usize> for HistoryBytes {
    type Error = HistoryError;
    fn try_from(value: usize) -> Result<Self, HistoryError> {
        if value > limits::HISTORY_BYTES {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
impl HistoryBytes {
    /// Exact retained and reserved byte count.
    pub fn get(self) -> usize {
        self.0
    }
}
