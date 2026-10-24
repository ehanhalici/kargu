//! Bounded prefix or rolling-tail archives with absolute byte cursors.

use super::OutputPage;
use crate::{
    application::RunHandle,
    constants::limits,
    domain::{ByteLimit, ByteOffset, OutputLimit, OutputRetention},
    error::CoreError,
};
use std::collections::VecDeque;

pub(super) struct Archive {
    bytes: VecDeque<u8>,
    seen: ByteOffset,
    retention: OutputRetention,
    limit: OutputLimit,
    truncated: bool,
    pub(super) eof: bool,
}
impl Archive {
    pub fn new(retention: OutputRetention, limit: OutputLimit) -> Self {
        Self {
            bytes: VecDeque::new(),
            seen: ByteOffset::ZERO,
            retention,
            limit,
            truncated: false,
            eof: false,
        }
    }
    pub fn push(&mut self, input: &[u8], run: &RunHandle) -> Result<(), CoreError> {
        self.seen = self.seen.checked_add(offset(input.len())?)?;
        let room = self
            .limit
            .as_usize()
            .saturating_sub(self.bytes.len())
            .min(input.len());
        let growth = if room == 0 {
            0
        } else {
            run.reserve_output(ByteLimit::try_from(room)?)
        };
        match self.retention {
            OutputRetention::Prefix => {
                self.bytes.extend(input.iter().take(growth));
                self.truncated |= growth < input.len();
            }
            OutputRetention::Tail => self.push_tail(input, growth)?,
        }
        Ok(())
    }
    fn push_tail(&mut self, input: &[u8], growth: usize) -> Result<(), CoreError> {
        let capacity = self
            .bytes
            .len()
            .checked_add(growth)
            .ok_or(CoreError::ArithmeticOverflow)?;
        if capacity == 0 {
            self.truncated |= !input.is_empty();
            return Ok(());
        }
        let combined = self
            .bytes
            .len()
            .checked_add(input.len())
            .ok_or(CoreError::ArithmeticOverflow)?;
        self.truncated |= combined > capacity;
        if input.len() >= capacity {
            self.bytes.clear();
            self.bytes
                .extend(input.iter().skip(input.len().saturating_sub(capacity)));
        } else {
            let discard = combined.saturating_sub(capacity);
            self.bytes.drain(..discard);
            self.bytes.extend(input);
        }
        Ok(())
    }
    pub fn snapshot(&self, limit: ByteLimit) -> (Vec<u8>, bool) {
        (
            self.bytes.iter().take(limit.as_usize()).copied().collect(),
            self.truncated || self.bytes.len() > limit.as_usize(),
        )
    }
    pub fn page(&self, cursor: ByteOffset) -> Result<OutputPage, CoreError> {
        self.page_limit(cursor, ByteLimit::try_from(limits::PROCESS_PAGE_BYTES)?)
    }
    pub fn page_limit(
        &self,
        cursor: ByteOffset,
        limit: ByteLimit,
    ) -> Result<OutputPage, CoreError> {
        if cursor > self.seen {
            return Err(CoreError::InvalidValue {
                field: "OutputCursor",
            });
        }
        let base = match self.retention {
            OutputRetention::Prefix => ByteOffset::ZERO,
            OutputRetention::Tail => ByteOffset::try_from(
                self.seen
                    .as_u64()
                    .saturating_sub(offset(self.bytes.len())?.as_u64()),
            )?,
        };
        let start_cursor = cursor.max(base);
        let start = usize::try_from(start_cursor.as_u64().saturating_sub(base.as_u64()))
            .map_err(|_| CoreError::ArithmeticOverflow)?;
        let bytes: Vec<_> = self
            .bytes
            .iter()
            .skip(start)
            .take(limit.as_usize().min(limits::PROCESS_PAGE_BYTES))
            .copied()
            .collect();
        let end = start
            .checked_add(bytes.len())
            .ok_or(CoreError::ArithmeticOverflow)?;
        let next_cursor = if end >= self.bytes.len() {
            self.seen
        } else {
            start_cursor.checked_add(offset(bytes.len())?)?
        };
        Ok(OutputPage {
            bytes,
            start_cursor,
            next_cursor,
            truncated: self.truncated,
            eof: self.eof,
        })
    }
}

fn offset(value: usize) -> Result<ByteOffset, CoreError> {
    ByteOffset::try_from(u64::try_from(value).map_err(|_| CoreError::ArithmeticOverflow)?)
}
