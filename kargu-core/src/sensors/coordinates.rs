//! Exact end-exclusive source ranges and scalar-coordinate checks.

use super::types::{ScalarColumn, SourceLine};
use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// One-based line and zero-based Unicode scalar column.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Ord, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Position {
    /// Source line, independent of folding and narrowing.
    pub line: SourceLine,
    /// Scalar offset on this line; tabs count as one scalar.
    pub column: ScalarColumn,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RangeInput {
    start: Position,
    end: Position,
}

/// A validated end-exclusive range. Empty ranges are valid; reversed ranges are not.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "RangeInput")]
pub struct SourceRange {
    start: Position,
    end: Position,
}
impl TryFrom<RangeInput> for SourceRange {
    type Error = CoreError;
    fn try_from(value: RangeInput) -> Result<Self, CoreError> {
        if value.end < value.start {
            return Err(CoreError::InvalidValue {
                field: "SourceRange",
            });
        }
        Ok(Self {
            start: value.start,
            end: value.end,
        })
    }
}
impl SourceRange {
    /// Whether another end-exclusive range lies entirely within this range.
    pub fn contains(self, other: Self) -> bool {
        self.start <= other.start && other.end <= self.end
    }
    /// First included source position.
    pub fn start(self) -> Position {
        self.start
    }
    /// First excluded source position.
    pub fn end(self) -> Position {
        self.end
    }
    /// Check both positions against the exact detached snapshot, without clamping.
    pub fn check_text(self, text: &str) -> Result<(), CoreError> {
        offset(text, self.start)?;
        offset(text, self.end)?;
        Ok(())
    }
}

/// Byte offset of scalar `column` inside one line, excluding its terminator.
fn column_offset(part: &str, column: usize) -> Result<usize, CoreError> {
    let body = match part.strip_suffix('\n') {
        Some(body) => body.strip_suffix('\r').unwrap_or(body),
        None => part,
    };
    if column == body.chars().count() {
        return Ok(body.len());
    }
    body.char_indices()
        .nth(column)
        .map(|(index, _)| index)
        .ok_or(CoreError::InvalidValue {
            field: "ScalarColumn",
        })
}

/// Convert an exact scalar position into a UTF-8 byte offset in a snapshot.
pub fn offset(text: &str, position: Position) -> Result<usize, CoreError> {
    let target = position.line.get();
    let column = usize::try_from(position.column.get()).map_err(|_| CoreError::Limit)?;
    let mut line = 1u64;
    let mut start = 0usize;
    for part in text.split_inclusive('\n') {
        if line == target {
            return start
                .checked_add(column_offset(part, column)?)
                .ok_or(CoreError::ArithmeticOverflow);
        }
        start = start
            .checked_add(part.len())
            .ok_or(CoreError::ArithmeticOverflow)?;
        line = line.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?;
    }
    // Empty input and the empty line after a final newline are real positions.
    if line == target && column == 0 && (text.is_empty() || text.ends_with('\n')) {
        return Ok(text.len());
    }
    Err(CoreError::InvalidValue {
        field: "SourceLine",
    })
}
