use super::{
    HistoryBytes, HistoryError, HistoryRevision, Message, ProviderCall, ProviderCallId, Role,
};
use crate::{
    constants::limits,
    domain::{MessageId, ToolCallId, ToolSafetyLevel},
    run::{ToolOutcome, ToolResult},
};
use std::{collections::HashMap, sync::Arc};

/// One immutable committed message and its native identity.
#[derive(Clone)]
pub struct StoredMessage {
    id: MessageId,
    message: Arc<Message>,
}
impl StoredMessage {
    /// Stable native message identity, independent of provider call IDs.
    pub fn id(&self) -> &MessageId {
        &self.id
    }
    /// Borrow immutable canonical protocol content.
    pub fn message(&self) -> &Message {
        &self.message
    }
    /// Construct ephemeral stored message for outbound payload without mutating store.
    pub fn ephemeral(message: Message) -> Self {
        Self {
            id: MessageId::new(),
            message: Arc::new(message),
        }
    }
}

#[derive(Clone, Copy)]
struct CallIndex(usize);
struct CallRecord {
    native_id: ToolCallId,
    source: Arc<Message>,
    index: CallIndex,
    result: Option<MessageId>,
    started: Option<ToolSafetyLevel>,
    outcome: Option<ToolOutcome>,
}
impl CallRecord {
    fn call(&self) -> Result<&ProviderCall, HistoryError> {
        self.source
            .calls()
            .get(self.index.0)
            .ok_or(HistoryError::InvalidMessage)
    }
}

/// One pending invocation, already committed by the model turn.
/// Its native ID must be registered at the shared gate before execution.
pub struct PendingCall<'a> {
    /// Native execution-ledger identity.
    pub native_id: &'a ToolCallId,
    /// Exact provider identity, parsed name and argument object.
    pub call: &'a ProviderCall,
}

#[derive(Clone, Copy, Default)]
struct PendingResults(usize);

/// Bounded single-writer store. It never performs IO or calls an editor/provider.
#[derive(Default)]
pub struct History {
    revision: HistoryRevision,
    messages: Vec<StoredMessage>,
    message_index: HashMap<MessageId, usize>,
    calls: HashMap<ProviderCallId, CallRecord>,
    call_order: Vec<ProviderCallId>,
    accounted: HistoryBytes,
    pending: PendingResults,
}
impl History {
    /// Current committed revision.
    pub fn revision(&self) -> HistoryRevision {
        self.revision
    }
    /// Wire and cached display bytes plus committed pending-result reservations.
    pub fn accounted_bytes(&self) -> HistoryBytes {
        self.accounted
    }
    /// Detached immutable snapshot. Existing messages are shared, never mutable views.
    pub fn snapshot(&self) -> Vec<StoredMessage> {
        self.messages.clone()
    }
    pub(super) fn messages(&self) -> &[StoredMessage] {
        &self.messages
    }
    pub(crate) fn answer_message(&self) -> Option<&MessageId> {
        let message = self.messages.last()?;
        (message.message().role() == super::Role::Assistant
            && message.message().calls().is_empty()
            && message
                .message()
                .display_text()
                .is_some_and(|text| !text.trim().is_empty()))
        .then_some(message.id())
    }
    pub(super) fn message(&self, id: &MessageId) -> Option<&StoredMessage> {
        self.message_index
            .get(id)
            .and_then(|index| self.messages.get(*index))
    }
    /// Whether another model turn may observe a complete call/result protocol.
    pub fn settled(&self) -> bool {
        self.pending.0 == 0
    }

    /// Calculate capacity before mutation so an application can enforce its aggregate cap.
    pub fn projected_bytes(&self, message: &Message) -> Result<HistoryBytes, HistoryError> {
        let new_calls = message.calls().len();
        let (pending, released) = if message.role() == Role::Tool {
            let id = message.result_id().ok_or(HistoryError::OrphanResult)?;
            let call = self.calls.get(id).ok_or(HistoryError::OrphanResult)?;
            if call.result.is_some() {
                return Err(HistoryError::DuplicateResult);
            }
            let expected_name = call.call()?.name();
            if message
                .result_name()
                .is_some_and(|name| name != expected_name)
            {
                return Err(HistoryError::InvalidMessage);
            }
            (
                self.pending
                    .0
                    .checked_sub(1)
                    .ok_or(HistoryError::InvalidMessage)?,
                limits::HISTORY_REPAIR_BYTES,
            )
        } else {
            if !self.settled() {
                return Err(HistoryError::PendingCalls);
            }
            if message
                .calls()
                .iter()
                .any(|call| self.calls.contains_key(call.id()))
            {
                return Err(HistoryError::DuplicateCall);
            }
            (new_calls, 0)
        };
        if self
            .messages
            .len()
            .checked_add(1)
            .and_then(|n| n.checked_add(pending))
            .is_none_or(|count| count > limits::HISTORY_MESSAGES)
            || self
                .calls
                .len()
                .checked_add(new_calls)
                .is_none_or(|n| n > limits::HISTORY_CALLS)
        {
            return Err(HistoryError::Limit);
        }
        let bytes = self
            .accounted
            .get()
            .checked_sub(released)
            .and_then(|n| n.checked_add(message.bytes()))
            .and_then(|n| n.checked_add(new_calls.checked_mul(limits::HISTORY_REPAIR_BYTES)?))
            .ok_or(HistoryError::Overflow)?;
        HistoryBytes::try_from(bytes)
    }

    /// Commit one complete canonical message after all checks, without partial batch mutation.
    pub fn append(&mut self, message: Message) -> Result<MessageId, HistoryError> {
        let accounted = self.projected_bytes(&message)?;
        let revision = self.revision.next()?;
        let id = MessageId::new();
        let message = Arc::new(message);
        if let Some(result_id) = message.result_id() {
            self.calls
                .get_mut(result_id)
                .ok_or(HistoryError::OrphanResult)?
                .result = Some(id.clone());
            self.pending.0 = self
                .pending
                .0
                .checked_sub(1)
                .ok_or(HistoryError::InvalidMessage)?;
        } else {
            self.pending = PendingResults(message.calls().len());
            for (index, call) in message.calls().iter().enumerate() {
                self.call_order.push(call.id().clone());
                self.calls.insert(
                    call.id().clone(),
                    CallRecord {
                        native_id: ToolCallId::new(),
                        source: message.clone(),
                        index: CallIndex(index),
                        result: None,
                        started: None,
                        outcome: None,
                    },
                );
            }
        }
        self.message_index.insert(id.clone(), self.messages.len());
        self.messages.push(StoredMessage {
            id: id.clone(),
            message,
        });
        self.accounted = accounted;
        self.revision = revision;
        Ok(id)
    }

    /// Borrow pending calls in their original batch order.
    pub fn pending_calls(&self) -> Result<Vec<PendingCall<'_>>, HistoryError> {
        let mut pending = Vec::with_capacity(self.pending.0);
        for id in &self.call_order {
            let record = self.calls.get(id).ok_or(HistoryError::InvalidMessage)?;
            if record.result.is_none() {
                pending.push(PendingCall {
                    native_id: &record.native_id,
                    call: record.call()?,
                });
            }
        }
        Ok(pending)
    }

    /// Borrow exactly one still-unanswered provider call without scanning another batch.
    pub fn pending_call(&self, id: &ProviderCallId) -> Result<PendingCall<'_>, HistoryError> {
        let record = self.calls.get(id).ok_or(HistoryError::OrphanResult)?;
        if record.result.is_some() {
            return Err(HistoryError::DuplicateResult);
        }
        Ok(PendingCall {
            native_id: &record.native_id,
            call: record.call()?,
        })
    }

    /// Resolve a native execution identity without inventing or rewriting a provider ID.
    pub fn provider_id(&self, native: &ToolCallId) -> Option<&ProviderCallId> {
        self.calls
            .iter()
            .find_map(|(id, record)| (&record.native_id == native).then_some(id))
    }

    /// Record actual executor entry after native gate admission, never merely dispatch intent.
    pub fn mark_started(
        &mut self,
        id: &ProviderCallId,
        safety: ToolSafetyLevel,
    ) -> Result<(), HistoryError> {
        let record = self.calls.get_mut(id).ok_or(HistoryError::OrphanResult)?;
        if record.result.is_some() || record.started.is_some() {
            return Err(HistoryError::DuplicateResult);
        }
        record.started = Some(safety);
        Ok(())
    }

    /// Commit a classified native completion exactly once. Human output does not determine status.
    pub fn append_result(
        &mut self,
        id: &ProviderCallId,
        outcome: ToolOutcome,
        text: &str,
    ) -> Result<MessageId, HistoryError> {
        let message = self.result_message(id, text)?;
        let committed = self.append(message)?;
        self.calls
            .get_mut(id)
            .ok_or(HistoryError::OrphanResult)?
            .outcome = Some(outcome);
        Ok(committed)
    }

    /// Build a result using the original requested tool name, preserving alias identity.
    pub fn result_message(&self, id: &ProviderCallId, text: &str) -> Result<Message, HistoryError> {
        let call = self.calls.get(id).ok_or(HistoryError::OrphanResult)?;
        Message::result(id, call.call()?.name(), text)
    }

    /// Fill only missing results after actual drain. Existing real/synthetic results survive.
    /// A started mutating executor with no completion remains outcome_unknown.
    pub fn repair_missing(
        &mut self,
        outcomes: &[ToolResult],
        fallback: ToolOutcome,
    ) -> Result<usize, HistoryError> {
        let mut repairs = Vec::with_capacity(self.pending.0);
        if outcomes.len() > limits::HISTORY_CALLS {
            return Err(HistoryError::Limit);
        }
        let reported: HashMap<_, _> = outcomes
            .iter()
            .map(|result| (&result.tool_call_id, result.outcome))
            .collect();
        if reported.len() != outcomes.len() {
            return Err(HistoryError::DuplicateCall);
        }
        for id in &self.call_order {
            let record = self.calls.get(id).ok_or(HistoryError::InvalidMessage)?;
            if record.result.is_some() {
                continue;
            }
            let outcome =
                reported
                    .get(&record.native_id)
                    .copied()
                    .unwrap_or(match record.started {
                        Some(
                            ToolSafetyLevel::MutatesState | ToolSafetyLevel::ExecutesArbitraryCode,
                        ) => ToolOutcome::OutcomeUnknown,
                        _ => fallback,
                    });
            let message = Message::result(id, record.call()?.name(), outcome.summary())?;
            if message.bytes() > limits::HISTORY_REPAIR_BYTES {
                return Err(HistoryError::Limit);
            }
            repairs.push((id.clone(), outcome, message));
        }
        let count = repairs.len();
        for (id, outcome, message) in repairs {
            self.append(message)?;
            self.calls
                .get_mut(&id)
                .ok_or(HistoryError::OrphanResult)?
                .outcome = Some(outcome);
        }
        Ok(count)
    }

    /// Build a private validated import. The caller's live store is never changed on failure.
    pub fn import(messages: impl IntoIterator<Item = Message>) -> Result<Self, HistoryError> {
        let mut candidate = Self::default();
        for message in messages {
            candidate.append(message)?;
        }
        Ok(candidate)
    }

    /// Adopt an already validated import at an exact idle-session revision.
    pub fn replace(
        &mut self,
        expected: HistoryRevision,
        mut candidate: Self,
    ) -> Result<(), HistoryError> {
        if expected != self.revision {
            return Err(HistoryError::StaleRevision);
        }
        if !self.settled() {
            return Err(HistoryError::PendingCalls);
        }
        candidate.revision = self.revision.next()?;
        *self = candidate;
        Ok(())
    }

    /// Extract preserved tail ensuring tool-call atomic block integrity.
    pub fn extract_tail(
        &self,
        keep: super::CompactKeep,
    ) -> Result<super::PreservedTail, HistoryError> {
        if !self.settled() {
            return Err(HistoryError::PendingCalls);
        }
        Ok(super::compact::extract_tail(&self.messages, keep))
    }

    /// Prepare a summary candidate capturing exact revision and atomic tail.
    pub fn prepare_compaction(
        &self,
        keep: super::CompactKeep,
        prompt: Message,
    ) -> Result<super::SummaryCandidate, HistoryError> {
        let tail = self.extract_tail(keep)?;
        Ok(super::SummaryCandidate::new(self.revision, tail, prompt))
    }
}
