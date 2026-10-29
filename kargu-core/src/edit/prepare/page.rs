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
        let envelope = serde_json::to_vec(
            &json!({"files":[],"offset":crate::constants::limits::EDIT_FILES,
            "next_offset":crate::constants::limits::EDIT_FILES,"complete":false}),
        )
        .map_err(|_| CoreError::Limit)?;
        let reserve = envelope.len().checked_sub(2).ok_or(CoreError::Limit)?;
        Ok(Self {
            files: Vec::new(),
            bytes: EncodedBytes(2),
            limit: ByteLimit::try_from(frame.as_usize().saturating_sub(reserve))?,
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metadata_pages_fit_the_exact_rpc_id_including_escaped_unicode() -> Result<(), CoreError> {
        use crate::ipc::protocol::{RpcId, success};
        let frame = ByteLimit::try_from(1024)?;
        for spelling in [
            "simple".to_owned(),
            "long-client-id-".repeat(20),
            "\"\\🦀".repeat(30),
        ] {
            let id = RpcId::String(spelling);
            let mut page = MetadataPage::new(id.result_budget(frame)?)?;
            for index in 0..12 {
                if !page.push(json!({"file":index,"path":"safe".repeat(25)}))? {
                    break;
                }
            }
            let value = page.finish(FileCursor::default(), FileCount::try_from(12)?)?;
            assert!(value["next_offset"].as_u64().is_some_and(|n| n > 0));
            assert!(
                serde_json::to_vec(&success(&id, value))
                    .map_err(|_| CoreError::Limit)?
                    .len()
                    <= frame.as_usize()
            );
        }
        Ok(())
    }
}
