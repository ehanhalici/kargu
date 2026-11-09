//! Pure mention DTOs. Parse results grant no file access or context egress.

use super::mentions::MentionLexer;
use crate::{
    constants::{limits, protocol::error_codes},
    domain::rpc::Fault,
    domain::{ByteLimit, RequestScope},
    edit::types::CaptureDigest,
};
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct Epoch(RequestScope);
impl TryFrom<String> for Epoch {
    type Error = Fault;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        RequestScope::try_from(value)
            .map(Self)
            .map_err(|_| Fault::params())
    }
}
#[derive(Deserialize)]
#[serde(try_from = "String")]
struct Source(Zeroizing<String>);
impl TryFrom<String> for Source {
    type Error = Fault;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let value = Zeroizing::new(value);
        if value.len() > limits::MENTION_SOURCE_BYTES {
            return Err(limit());
        }
        Ok(Self(value))
    }
}
#[derive(Default, Deserialize)]
#[serde(try_from = "usize")]
struct TargetOffset(usize);
impl TryFrom<usize> for TargetOffset {
    type Error = Fault;
    fn try_from(value: usize) -> Result<Self, Self::Error> {
        if value > limits::MENTION_TARGETS {
            return Err(Fault::params());
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ParseRequest {
    connection_epoch: Epoch,
    source: Source,
    #[serde(default)]
    offset: TargetOffset,
}
impl ParseRequest {
    pub fn decode(value: Value) -> Result<Self, Fault> {
        serde_json::from_value(value).map_err(|_| Fault::params())
    }
    pub fn epoch(&self) -> &RequestScope {
        &self.connection_epoch.0
    }
    pub fn page(self, frame: ByteLimit) -> Result<Value, Fault> {
        let spans = MentionLexer::new(&self.source.0)
            .parse_bounded()
            .ok_or_else(limit)?;
        if self.offset.0 > spans.len() {
            return Err(Fault::params());
        }
        let hash = CaptureDigest::capture(self.source.0.as_bytes());
        let mut page = json!({"source_hash":hash,"source_bytes":self.source.0.len(),
            "coordinates":"utf8_bytes","offset":self.offset.0,"next_offset":self.offset.0,
            "total":spans.len(),"done":self.offset.0 == spans.len(),"spans":[]});
        let mut entries = Vec::new();
        let mut next_offset = self.offset.0;
        for span in spans.iter().skip(self.offset.0) {
            entries.push(span);
            let next = self.offset.0.saturating_add(entries.len());
            let candidate = json!({"source_hash":hash,"source_bytes":self.source.0.len(),
                "coordinates":"utf8_bytes","offset":self.offset.0,"next_offset":next,
                "total":spans.len(),"done":next == spans.len(),"spans":entries});
            if candidate.to_string().len() > frame.as_usize() {
                break;
            }
            next_offset = next;
            page = candidate;
        }
        if (next_offset == self.offset.0 && self.offset.0 < spans.len())
            || page.to_string().len() > frame.as_usize()
        {
            return Err(limit());
        }
        Ok(page)
    }
}
fn limit() -> Fault {
    Fault::new(
        error_codes::RESOURCE_LIMIT,
        "Mention parse limit exceeded",
        "resource_limit",
    )
}
