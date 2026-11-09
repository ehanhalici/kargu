//! Application-actor-only conversation writes and aggregate history admission.

use super::{ApplicationActor, RunHandle, RunPurpose, ToolOutcome};
use crate::{
    constants::limits,
    domain::{MessageId, SessionId, ToolCallId},
    error::CoreError,
    history::{History, HistoryRevision, Message, StoredMessage},
};

impl ApplicationActor {
    /// Borrow the owned live conversation history; this does not admit a run.
    pub fn session_history(&self, session: &SessionId) -> Result<&History, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        self.histories.get(session).ok_or(CoreError::StaleOwner)
    }

    /// Capture immutable committed messages and revision for a detached reader.
    pub fn history_snapshot(
        &self,
        session: &SessionId,
    ) -> Result<(HistoryRevision, Vec<StoredMessage>), CoreError> {
        let history = self.session_history(session)?;
        Ok((history.revision(), history.snapshot()))
    }

    pub(super) fn check_history_capacity(
        &self,
        session: &SessionId,
        replacement: crate::history::HistoryBytes,
    ) -> Result<(), CoreError> {
        let bytes = self
            .histories
            .iter()
            .filter(|(id, _)| *id != session)
            .try_fold(replacement.get(), |bytes, (_, history)| {
                bytes.checked_add(history.accounted_bytes().get())
            })
            .ok_or(CoreError::ArithmeticOverflow)?;
        if bytes > limits::APPLICATION_HISTORY_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(())
    }

    /// Adopt a validated history only for an idle live conversation at its exact revision.
    /// Active and draining owners cannot be bypassed through this import path.
    pub fn import_history(
        &mut self,
        session: &SessionId,
        expected: HistoryRevision,
        candidate: History,
    ) -> Result<(), CoreError> {
        self.session_history(session)?;
        if self
            .preparing
            .as_ref()
            .is_some_and(|pending| pending.claim().scope().session_id() == session)
        {
            return Err(CoreError::Busy);
        }
        if self.history_imports.owns_session(session) {
            return Err(CoreError::Busy);
        }
        if self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
            .any(|run| run.handle.scope().session_id() == session)
        {
            return Err(CoreError::Busy);
        }
        self.check_history_capacity(session, candidate.accounted_bytes())?;
        self.histories
            .get_mut(session)
            .ok_or(CoreError::StaleOwner)?
            .replace(expected, candidate)?;
        Ok(())
    }

    /// Commit a complete user/model message under the actual foreground run claim.
    pub fn append_history(
        &mut self,
        run: &RunHandle,
        message: Message,
    ) -> Result<MessageId, CoreError> {
        if self.owned(run)?.agent.is_some() {
            return Err(CoreError::Rejected);
        }
        self.append_agent_message(run, message)
    }

    pub(super) fn append_agent_message(
        &mut self,
        run: &RunHandle,
        message: Message,
    ) -> Result<MessageId, CoreError> {
        self.validate(run)?;
        if run.scope().purpose() != RunPurpose::AgentTurn {
            return Err(CoreError::Rejected);
        }
        let session = run.scope().session_id();
        let projected = self
            .histories
            .get(session)
            .ok_or(CoreError::StaleOwner)?
            .projected_bytes(&message)?;
        self.check_history_capacity(session, projected)?;
        Ok(self
            .histories
            .get_mut(session)
            .ok_or(CoreError::StaleOwner)?
            .append(message)?)
    }

    /// Commit actual output and the native tool verdict in the same actor turn.
    /// Retired or cancelled runs may report facts while their claim is still draining;
    /// this grants no new execution authority.
    pub fn complete_history_call(
        &mut self,
        run: &RunHandle,
        native_id: &ToolCallId,
        outcome: ToolOutcome,
        text: &str,
    ) -> Result<MessageId, CoreError> {
        if self.call_steps_settled(run, native_id)? == Some(false) {
            return Err(CoreError::Busy);
        }
        let call = self
            .owned(run)?
            .calls
            .get(native_id)
            .ok_or(CoreError::StaleOwner)?;
        if call.outcome.is_some_and(|known| known != outcome) {
            return Err(CoreError::AlreadyCompleted);
        }
        let already_settled = call.outcome.is_some();
        if run.scope().purpose() != RunPurpose::AgentTurn {
            return Err(CoreError::Rejected);
        }
        let session = run.scope().session_id();
        let history = self.histories.get(session).ok_or(CoreError::StaleOwner)?;
        let provider = history
            .provider_id(native_id)
            .ok_or(CoreError::StaleOwner)?
            .clone();
        let sanitized = crate::application::agent::output::SanitizedToolOutput::sanitize(text);
        let message = history.result_message(&provider, sanitized.as_str())?;
        self.check_history_capacity(session, history.projected_bytes(&message)?)?;
        let id = self
            .histories
            .get_mut(session)
            .ok_or(CoreError::StaleOwner)?
            .append_result(&provider, outcome, sanitized.as_str())?;
        if !already_settled {
            self.complete_tool(run, native_id, outcome)?;
        }
        Ok(id)
    }

    /// Register a committed provider call once, before dispatch or approval.
    /// The gate later consumes this same native identity without a second budget debit.
    pub fn register_history_call(
        &mut self,
        run: &RunHandle,
        id: &crate::history::ProviderCallId,
        registry: &crate::policy::ToolRegistry,
    ) -> Result<ToolCallId, CoreError> {
        self.validate(run)?;
        if run.scope().purpose() != RunPurpose::AgentTurn {
            return Err(CoreError::Rejected);
        }
        let pending = self
            .histories
            .get(run.scope().session_id())
            .ok_or(CoreError::StaleOwner)?
            .pending_call(id)?;
        let native_id = pending.native_id.clone();
        // Unknown tools still receive a bounded, typed failure result; this never grants execution.
        let name = match registry.resolve(pending.call.name()) {
            Ok(descriptor) => descriptor.name().clone(),
            Err(CoreError::Unavailable) => pending.call.name().clone(),
            Err(error) => return Err(error),
        };
        self.register_call(run, native_id.clone(), name)?;
        Ok(native_id)
    }

    pub(super) fn prune_retired_histories(&mut self) {
        let sessions = &self.sessions;
        let active = &self.active;
        let jobs = &self.job_runs;
        let edits = &self.editor_runs;
        let preparing = &self.preparing;
        self.histories.retain(|session, _| {
            sessions.contains(session)
                || preparing
                    .as_ref()
                    .is_some_and(|pending| pending.claim().scope().session_id() == session)
                || active
                    .iter()
                    .chain(jobs.values())
                    .chain(edits.values())
                    .any(|run| run.handle.scope().session_id() == session)
        });
    }

    pub(crate) fn history_rpc(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: serde_json::Value,
        frame: crate::domain::ByteLimit,
    ) -> Result<serde_json::Value, crate::domain::rpc::Fault> {
        let revision = self
            .session_history(session)
            .map_err(crate::history::fault)?
            .revision();
        if method == crate::constants::protocol::methods::HISTORY_BEGIN
            && (self
                .preparing
                .as_ref()
                .is_some_and(|pending| pending.claim().scope().session_id() == session)
                || self
                    .active
                    .iter()
                    .chain(self.job_runs.values())
                    .chain(self.editor_runs.values())
                    .any(|run| run.handle.scope().session_id() == session))
        {
            return Err(crate::history::fault(CoreError::Busy));
        }
        self.history_imports
            .rpc(
                session,
                revision,
                method,
                arguments,
                frame,
                std::time::Instant::now(),
            )
            .map_err(crate::history::fault)
    }

    pub(crate) fn prepare_history_import(
        &mut self,
        session: &SessionId,
        arguments: serde_json::Value,
    ) -> Result<crate::history::HistoryWork, CoreError> {
        self.session_history(session)?;
        self.history_imports
            .take(session, arguments, std::time::Instant::now())
    }

    pub(crate) fn can_publish_history(
        &self,
        session: &SessionId,
        id: &crate::domain::HistoryUploadId,
    ) -> bool {
        self.owns_session(session)
            && self
                .history_imports
                .can_publish(session, id, std::time::Instant::now())
    }

    pub(crate) fn finish_history_import(
        &mut self,
        session: &SessionId,
        id: &crate::domain::HistoryUploadId,
        result: Result<History, CoreError>,
    ) -> Result<serde_json::Value, CoreError> {
        // Consuming the actual-join permit always releases the staged reservation,
        // including closed sessions, cancellation and invalid candidate failures.
        let expected = self
            .history_imports
            .finish(session, id, std::time::Instant::now())?;
        let candidate = result?;
        self.import_history(session, expected, candidate)?;
        let history = self.session_history(session)?;
        Ok(
            serde_json::json!({"revision":history.revision(),"bytes":history.accounted_bytes(),
                             "messages_total":history.snapshot().len()}),
        )
    }
}
