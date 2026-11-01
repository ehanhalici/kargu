//! Owned import staging. Validation runs on an existing bounded read worker.

use super::{History, HistoryError, HistoryRevision, Message};
use crate::{
    application::ToolOutcome,
    constants::{limits, protocol::methods, timeouts},
    domain::{ApiPageBytes, ByteLimit, HistoryUploadId, SessionId},
    error::CoreError,
    security::file::checkpoint,
};
use serde::{
    Deserialize,
    de::{SeqAccess, Visitor},
};
use serde_json::{Value, json, value::RawValue};
use std::{collections::HashMap, fmt, time::Instant};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "usize")]
struct UploadBytes(usize);
impl TryFrom<usize> for UploadBytes {
    type Error = HistoryError;
    fn try_from(value: usize) -> Result<Self, HistoryError> {
        if !(2..=limits::HISTORY_BYTES).contains(&value) {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "usize")]
struct UploadOffset(usize);
impl TryFrom<usize> for UploadOffset {
    type Error = HistoryError;
    fn try_from(value: usize) -> Result<Self, HistoryError> {
        if value > limits::HISTORY_BYTES {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(try_from = "String")]
struct UploadChunk(Zeroizing<String>);
impl TryFrom<String> for UploadChunk {
    type Error = HistoryError;
    fn try_from(value: String) -> Result<Self, HistoryError> {
        let value = Zeroizing::new(value);
        if value.len() > limits::EDIT_PAGE_BYTES {
            return Err(HistoryError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Begin {
    revision: HistoryRevision,
    bytes: UploadBytes,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Append {
    upload_id: HistoryUploadId,
    offset: UploadOffset,
    text: UploadChunk,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ticket {
    upload_id: HistoryUploadId,
}
enum Phase {
    Uploading(Zeroizing<String>),
    Preparing { revoked: bool },
}
struct Entry {
    session: SessionId,
    revision: HistoryRevision,
    expected: UploadBytes,
    expires: Instant,
    phase: Phase,
}
#[derive(Default)]
pub(crate) struct HistoryImports {
    entries: HashMap<HistoryUploadId, Entry>,
}

pub(crate) struct HistoryWork {
    pub id: HistoryUploadId,
    source: Zeroizing<String>,
    expires: Instant,
}
struct Messages(Vec<Box<RawValue>>);
impl<'de> Deserialize<'de> for Messages {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Bounded;
        impl<'de> Visitor<'de> for Bounded {
            type Value = Messages;
            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("bounded canonical conversation messages")
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Messages, A::Error> {
                let mut messages = Vec::new();
                while let Some(message) = sequence.next_element::<Box<RawValue>>()? {
                    if messages.len() >= limits::HISTORY_MESSAGES {
                        return Err(serde::de::Error::custom("history message limit exceeded"));
                    }
                    messages.push(message);
                }
                Ok(Messages(messages))
            }
        }
        deserializer.deserialize_seq(Bounded)
    }
}
impl HistoryWork {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<History, CoreError> {
        let deadline = deadline.min(self.expires);
        checkpoint(cancel, deadline)?;
        let messages: Messages =
            serde_json::from_str(&self.source).map_err(|_| HistoryError::InvalidMessage)?;
        let mut history = History::default();
        for message in messages.0 {
            checkpoint(cancel, deadline)?;
            history.append(Message::try_from(message)?)?;
        }
        // Imported interrupted effects are facts to inspect, never work to replay.
        history.repair_missing(&[], ToolOutcome::OutcomeUnknown)?;
        checkpoint(cancel, deadline)?;
        Ok(history)
    }
}
impl HistoryImports {
    pub(crate) fn owns_session(&self, session: &SessionId) -> bool {
        let now = Instant::now();
        self.entries.values().any(|entry| {
            &entry.session == session
                && (matches!(entry.phase, Phase::Preparing { .. }) || now < entry.expires)
        })
    }
    pub(crate) fn drained(&self) -> bool {
        !self
            .entries
            .values()
            .any(|entry| matches!(entry.phase, Phase::Preparing { .. }))
    }
    pub(crate) fn revoke(&mut self, session: Option<&SessionId>) {
        self.entries.retain(|_, entry| {
            if session.is_some_and(|session| session != &entry.session) {
                return true;
            }
            match &mut entry.phase {
                Phase::Uploading(_) => false,
                Phase::Preparing { revoked } => {
                    *revoked = true;
                    true
                }
            }
        });
    }
    fn sweep(&mut self, now: Instant) {
        self.entries.retain(|_, entry| {
            if now < entry.expires {
                return true;
            }
            match &mut entry.phase {
                Phase::Uploading(_) => false,
                Phase::Preparing { revoked } => {
                    *revoked = true;
                    true
                }
            }
        });
    }
    pub(crate) fn rpc(
        &mut self,
        session: &SessionId,
        revision: HistoryRevision,
        method: &str,
        arguments: Value,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        self.sweep(now);
        match method {
            methods::HISTORY_BEGIN => {
                let input: Begin =
                    serde_json::from_value(arguments).map_err(|_| HistoryError::InvalidMessage)?;
                if input.revision != revision {
                    return Err(HistoryError::StaleRevision.into());
                }
                if self.owns_session(session) {
                    return Err(CoreError::Busy);
                }
                let total = self
                    .entries
                    .values()
                    .try_fold(input.bytes.0, |bytes, entry| {
                        bytes.checked_add(entry.expected.0)
                    })
                    .ok_or(CoreError::ArithmeticOverflow)?;
                if self.entries.len() >= limits::HISTORY_UPLOADS || total > limits::HISTORY_BYTES {
                    return Err(CoreError::Limit);
                }
                let page = ApiPageBytes::try_from(frame)?;
                let upload_id = HistoryUploadId::new();
                self.entries.insert(
                    upload_id.clone(),
                    Entry {
                        session: session.clone(),
                        revision,
                        expected: input.bytes,
                        expires: now
                            .checked_add(timeouts::HISTORY_IMPORT)
                            .ok_or(CoreError::ArithmeticOverflow)?,
                        phase: Phase::Uploading(Zeroizing::new(String::new())),
                    },
                );
                Ok(
                    json!({"upload_id":upload_id,"revision":revision,"offset":0,"page_bytes":page.as_usize()}),
                )
            }
            methods::HISTORY_APPEND => {
                let input: Append =
                    serde_json::from_value(arguments).map_err(|_| HistoryError::InvalidMessage)?;
                let entry = self
                    .entries
                    .get_mut(&input.upload_id)
                    .filter(|entry| &entry.session == session)
                    .ok_or(CoreError::StaleOwner)?;
                let Phase::Uploading(source) = &mut entry.phase else {
                    return Err(CoreError::AlreadyCompleted);
                };
                if source.len() != input.offset.0 {
                    return Err(HistoryError::InvalidMessage.into());
                }
                let next = source
                    .len()
                    .checked_add(input.text.0.len())
                    .ok_or(CoreError::ArithmeticOverflow)?;
                if next > entry.expected.0 {
                    return Err(CoreError::Limit);
                }
                source.push_str(&input.text.0);
                Ok(
                    json!({"upload_id":input.upload_id,"offset":next,"complete":next==entry.expected.0}),
                )
            }
            methods::HISTORY_ABORT => {
                let input: Ticket =
                    serde_json::from_value(arguments).map_err(|_| HistoryError::InvalidMessage)?;
                let entry = self
                    .entries
                    .get_mut(&input.upload_id)
                    .filter(|entry| &entry.session == session)
                    .ok_or(CoreError::StaleOwner)?;
                if let Phase::Preparing { revoked } = &mut entry.phase {
                    *revoked = true;
                } else {
                    self.entries.remove(&input.upload_id);
                }
                Ok(json!({"aborted":true}))
            }
            _ => Err(CoreError::Unavailable),
        }
    }
    pub(crate) fn take(
        &mut self,
        session: &SessionId,
        arguments: Value,
        now: Instant,
    ) -> Result<HistoryWork, CoreError> {
        self.sweep(now);
        let input: Ticket =
            serde_json::from_value(arguments).map_err(|_| HistoryError::InvalidMessage)?;
        let entry = self
            .entries
            .get_mut(&input.upload_id)
            .filter(|entry| &entry.session == session)
            .ok_or(CoreError::StaleOwner)?;
        let Phase::Uploading(source) = &entry.phase else {
            return Err(CoreError::AlreadyCompleted);
        };
        if source.len() != entry.expected.0 {
            return Err(HistoryError::InvalidMessage.into());
        }
        let Phase::Uploading(source) =
            std::mem::replace(&mut entry.phase, Phase::Preparing { revoked: false })
        else {
            return Err(CoreError::AlreadyCompleted);
        };
        Ok(HistoryWork {
            id: input.upload_id,
            source,
            expires: entry.expires,
        })
    }
    pub(crate) fn can_publish(
        &self,
        session: &SessionId,
        id: &HistoryUploadId,
        now: Instant,
    ) -> bool {
        self.entries.get(id).is_some_and(|entry| {
            &entry.session == session
                && now < entry.expires
                && matches!(entry.phase, Phase::Preparing { revoked: false })
        })
    }
    pub(crate) fn finish(
        &mut self,
        session: &SessionId,
        id: &HistoryUploadId,
        now: Instant,
    ) -> Result<HistoryRevision, CoreError> {
        let entry = self.entries.get(id).ok_or(CoreError::StaleOwner)?;
        if &entry.session != session {
            return Err(CoreError::StaleOwner);
        }
        if !matches!(entry.phase, Phase::Preparing { .. }) {
            return Err(CoreError::AlreadyCompleted);
        }
        let entry = self.entries.remove(id).ok_or(CoreError::StaleOwner)?;
        if now >= entry.expires {
            return Err(CoreError::Deadline);
        }
        if !matches!(entry.phase, Phase::Preparing { revoked: false }) {
            return Err(CoreError::Cancelled);
        }
        Ok(entry.revision)
    }
}
