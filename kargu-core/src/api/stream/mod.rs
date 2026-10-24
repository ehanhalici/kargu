//! Bounded incremental SSE decoding and completion-gated tool reconstruction.

mod accumulator;
mod limits;
mod parser;
use super::ApiError;
use accumulator::Accumulator;
pub use limits::StreamLimits;
use parser::Parser;
use serde_json::Value;

/// Single-owner parser. Network byte boundaries never become UTF-8 boundaries.
pub struct StreamDecoder {
    parser: Parser,
    accumulator: Accumulator,
    failed: bool,
}
impl StreamDecoder {
    /// Create one decoder with a captured policy; no global mutable limits.
    pub fn new(limits: StreamLimits) -> Self {
        Self {
            parser: Parser::new(limits),
            accumulator: Accumulator::new(limits),
            failed: false,
        }
    }
    /// Feed arbitrary bytes and return validated, pre-completion UI delta events.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Value>, ApiError> {
        if self.failed {
            return Err(ApiError::Protocol);
        }
        let result = self
            .parser
            .feed(bytes)
            .and_then(|events| self.accept(events));
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    fn accept(&mut self, events: Vec<parser::Event>) -> Result<Vec<Value>, ApiError> {
        let mut deltas = Vec::new();
        for event in events {
            if let Some(delta) = self.accumulator.accept(event)? {
                deltas.push(delta);
            }
        }
        Ok(deltas)
    }
    /// Flush the last event and require explicit completion before returning calls.
    pub fn finish(mut self) -> Result<(Vec<Value>, Value), ApiError> {
        if self.failed {
            return Err(ApiError::Protocol);
        }
        let events = self.parser.finish()?;
        let deltas = self.accept(events)?;
        Ok((deltas, self.accumulator.finish()?))
    }
}
