//! Linear-time bounded metadata framing; no source text or filesystem work.
use super::types::{FileCount, FileCursor};
use crate::{domain::ByteLimit, edit::EditError, error::CoreError};
use serde_json::{Value, json};
struct EncodedBytes(usize);
pub(super) struct MetadataPage {
    files: Vec<Value>,
    bytes: EncodedBytes,
    limit: ByteLimit,
}
impl MetadataPage {
    pub(super) fn new(frame: ByteLimit) -> Result<Self, CoreError> {
        Ok(Self {
            files: Vec::new(),
            bytes: EncodedBytes(2),
            limit: ByteLimit::try_from(frame.as_usize().saturating_sub(256))?,
        })
    }
    pub(super) fn push(&mut self, value: Value) -> Result<bool, CoreError> {
        let bytes = serde_json::to_vec(&value)
            .map_err(|_| CoreError::Limit)?
            .len();
        let next = self
            .bytes
            .0
            .checked_add(bytes)
            .and_then(|n| n.checked_add(1))
            .ok_or(EditError::Limit)?;
        if next > self.limit.as_usize() {
            return Ok(false);
        }
        self.files.push(value);
        self.bytes = EncodedBytes(next);
        Ok(true)
    }
    pub(super) fn finish(self, offset: FileCursor, total: FileCount) -> Result<Value, CoreError> {
        let next = FileCursor::try_from(
            offset
                .get()
                .checked_add(self.files.len())
                .ok_or(EditError::Limit)?,
        )?;
        if next.get() == offset.get() && next.get() < total.get() {
            return Err(CoreError::Limit);
        }
        Ok(
            json!({"files":self.files,"offset":offset,"next_offset":next,"complete":next.get()==total.get()}),
        )
    }
}
