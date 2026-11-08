//! History compaction candidate preparation and atomic block tail extraction.

use super::{History, HistoryError, HistoryRevision, Message, Role, StoredMessage};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;

/// Number of trailing non-system messages to preserve during compaction.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CompactKeep(usize);

impl CompactKeep {
    /// Wrap a raw message count.
    pub const fn new(count: usize) -> Self {
        Self(count)
    }

    /// Extract the underlying message count.
    pub const fn get(self) -> usize {
        self.0
    }
}

impl From<usize> for CompactKeep {
    fn from(value: usize) -> Self {
        Self(value)
    }
}

/// Validated non-empty compaction summary text.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SummaryText(String);

impl SummaryText {
    /// Validate that summary text is non-empty after trimming.
    pub fn try_new(raw: &str) -> Result<Self, HistoryError> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err(HistoryError::InvalidMessage);
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Borrow validated summary text.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Extract and validate non-empty summary text from a completed assistant message.
    pub fn from_message(message: &Message) -> Result<Self, HistoryError> {
        let text = message.display_text().ok_or(HistoryError::InvalidMessage)?;
        Self::try_new(text)
    }
}

impl TryFrom<&str> for SummaryText {
    type Error = HistoryError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_new(value)
    }
}

/// Byte threshold above which settled conversation history should compact.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CompactThreshold(usize);

impl CompactThreshold {
    /// Default fallback threshold (45,000 bytes) when model context window is unknown.
    pub const DEFAULT: Self = Self(45_000);

    /// Compute threshold from optional model context window tokens (70% of 3.5 chars/token, capped at 800k).
    pub fn from_context_window(tokens: Option<u64>) -> Self {
        match tokens {
            Some(t) if t > 0 => {
                let scaled = (u128::from(t).saturating_mul(49).saturating_add(10)) / 20;
                Self(scaled.clamp(1, 800_000) as usize)
            }
            _ => Self::DEFAULT,
        }
    }

    /// Underlying byte threshold.
    pub const fn get(self) -> usize {
        self.0
    }

    /// True when settled messages exceed both the minimum message count (4 non-system) and byte threshold.
    pub fn is_exceeded_by(self, messages: &[StoredMessage]) -> bool {
        let non_system = messages
            .iter()
            .filter(|m| !matches!(m.message().role(), Role::System | Role::Developer))
            .count();
        let wire_bytes: usize = messages
            .iter()
            .map(|m| m.message().wire().get().len())
            .sum();
        self.0 > 0 && non_system > 4 && wire_bytes > self.0
    }
}

impl Default for CompactThreshold {
    fn default() -> Self {
        Self::DEFAULT
    }
}

const COMPACTION_REQUEST_PROMPT: &str = concat!(
    "COMPACTION_REQUEST: Summarize the conversation so far for another ",
    "coding agent. Output a structured summary with these headings: ",
    "Goal, Done, Files and symbols touched, Open issues, Next step. ",
    "Use exact paths. Do not continue the task. Do not call tools. ",
    "Reply with the summary only."
);

/// Construct the canonical tools-off compaction user request message.
pub fn compaction_prompt_message() -> Result<Message, HistoryError> {
    Message::user_text(COMPACTION_REQUEST_PROMPT)
}

/// Monotonic SHA-256 fingerprint over preserved tail message identities and wire bodies.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TailHash([u8; 32]);

impl TailHash {
    /// Wrap raw digest bytes.
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// Borrow underlying digest bytes.
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// Preserved immutable message slice ensuring tool-call atomic block integrity.
#[derive(Clone)]
pub struct PreservedTail {
    messages: Vec<StoredMessage>,
    hash: TailHash,
}

impl PreservedTail {
    /// Construct preserved tail with precomputed digest.
    pub fn new(messages: Vec<StoredMessage>, hash: TailHash) -> Self {
        Self { messages, hash }
    }

    /// Preserved messages in canonical order.
    pub fn messages(&self) -> &[StoredMessage] {
        &self.messages
    }

    /// Digest of preserved messages.
    pub fn hash(&self) -> TailHash {
        self.hash
    }
}

/// Bounded immutable compaction candidate prepared for an exact history revision.
#[derive(Clone)]
pub struct SummaryCandidate {
    source_revision: HistoryRevision,
    tail: PreservedTail,
    prompt: Arc<Message>,
}

impl SummaryCandidate {
    /// Assemble compaction candidate for an exact source revision.
    pub fn new(source_revision: HistoryRevision, tail: PreservedTail, prompt: Message) -> Self {
        Self {
            source_revision,
            tail,
            prompt: Arc::new(prompt),
        }
    }

    /// Exact history revision when this candidate was prepared.
    pub fn source_revision(&self) -> HistoryRevision {
        self.source_revision
    }

    /// Hash of preserved tail messages.
    pub fn tail_hash(&self) -> TailHash {
        self.tail.hash()
    }

    /// Preserved messages in canonical order.
    pub fn preserved_tail(&self) -> &[StoredMessage] {
        self.tail.messages()
    }

    /// Summary prompt message.
    pub fn prompt(&self) -> &Message {
        &self.prompt
    }
}

/// Compute SHA-256 digest over message identities and wire bodies.
pub fn compute_tail_hash(messages: &[StoredMessage]) -> TailHash {
    let mut hasher = Sha256::new();
    for msg in messages {
        hasher.update(msg.id().as_str().as_bytes());
        hasher.update(msg.message().wire().get().as_bytes());
    }
    TailHash(hasher.finalize().into())
}

fn rewind_tool_results(messages: &[StoredMessage], mut split: usize) -> usize {
    while split > 0
        && messages
            .get(split)
            .is_some_and(|m| m.message().role() == Role::Tool)
    {
        split -= 1;
    }
    split
}

fn align_user_turn(messages: &[StoredMessage], split: usize) -> usize {
    if split > 0
        && messages
            .get(split)
            .is_some_and(|m| m.message().role() == Role::Assistant)
        && messages
            .get(split - 1)
            .is_some_and(|m| m.message().role() == Role::User)
    {
        return split - 1;
    }
    split
}

fn find_atomic_split_index(messages: &[StoredMessage], candidate_split: usize) -> usize {
    let split = rewind_tool_results(messages, candidate_split);
    align_user_turn(messages, split)
}

fn filter_leading_system(messages: &[StoredMessage]) -> Vec<StoredMessage> {
    let drop = messages
        .first()
        .is_some_and(|m| m.message().role() == Role::System);
    let start = usize::from(drop);
    messages.get(start..).unwrap_or(&[]).to_vec()
}

/// Extract preserved tail from messages without severing atomic tool-call blocks.
pub fn extract_tail(messages: &[StoredMessage], keep: CompactKeep) -> PreservedTail {
    let keep_count = keep.get();
    if messages.is_empty() || keep_count == 0 {
        return PreservedTail::new(Vec::new(), compute_tail_hash(&[]));
    }
    let total = messages.len();
    let candidate_split = total.saturating_sub(keep_count);
    let split = find_atomic_split_index(messages, candidate_split);
    let tail_slice = messages.get(split..).unwrap_or(&[]);
    let tail_messages = if split == 0 {
        filter_leading_system(tail_slice)
    } else {
        tail_slice.to_vec()
    };
    let hash = compute_tail_hash(&tail_messages);
    PreservedTail::new(tail_messages, hash)
}

fn append_bridge_if_needed(
    msgs: &mut Vec<Message>,
    tail: &[StoredMessage],
) -> Result<(), HistoryError> {
    if tail
        .first()
        .is_some_and(|m| m.message().role() == Role::Assistant)
    {
        msgs.push(Message::user_text(
            "Please proceed with the task based on the summary above.",
        )?);
    }
    Ok(())
}

/// Assemble replacement conversation messages from summary text and preserved tail.
pub fn assemble_compacted_messages(
    sys_msg: Option<&Message>,
    summary: &SummaryText,
    tail: &[StoredMessage],
) -> Result<Vec<Message>, HistoryError> {
    let mut msgs = Vec::with_capacity(tail.len().saturating_add(4));
    if let Some(sys) = sys_msg {
        msgs.push(sys.clone());
    }
    let ack_content = format!("COMPACTION_ACK: Prior work summary:\n{}", summary.as_str());
    msgs.push(Message::user_text(&ack_content)?);
    msgs.push(Message::assistant_text(
        "Acknowledged. Continuing from the summary.",
    )?);
    append_bridge_if_needed(&mut msgs, tail)?;
    for stored in tail {
        msgs.push(stored.message().clone());
    }
    Ok(msgs)
}

/// Build replacement validated History from summary text and preserved tail.
pub fn build_compacted_history(
    sys_msg: Option<&Message>,
    summary: &SummaryText,
    tail: &[StoredMessage],
) -> Result<History, HistoryError> {
    let messages = assemble_compacted_messages(sys_msg, summary, tail)?;
    History::import(messages)
}
