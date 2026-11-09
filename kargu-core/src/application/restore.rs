//! Atomic restoration of candidate sessions into live application actor state.

use crate::{
    application::{
        ApplicationActor, Mode,
        mode::{ModeRevision, SessionMode},
        selection::{
            EffortChoice, EffortLabel, ModelChoice, Selection, SelectionRevision, SessionSelection,
        },
    },
    domain::{RequestCount, SessionEventSequence, SessionId, TokenCount},
    error::CoreError,
    history::{History, HistoryError, HistoryRevision, Message},
    persistence::{
        domain::{SessionEffort, SessionMessage, SessionRecord},
        migration::{CollisionPolicy, RawSessionPayload, migrate_candidate},
    },
    providers::ApiProviderId,
};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Monotonically tracked session usage counters.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct SessionAccounting {
    requests: RequestCount,
    #[serde(skip_serializing_if = "Option::is_none")]
    tokens_in: Option<TokenCount>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tokens_out: Option<TokenCount>,
    tokens_unknown: bool,
    monetary_unknown: bool,
}

impl SessionAccounting {
    /// Create new session accounting counters.
    pub const fn new(
        requests: RequestCount,
        tokens_in: Option<TokenCount>,
        tokens_out: Option<TokenCount>,
    ) -> Self {
        let tokens_unknown = tokens_in.is_none() && tokens_out.is_none();
        Self {
            requests,
            tokens_in,
            tokens_out,
            tokens_unknown,
            monetary_unknown: true,
        }
    }

    /// Number of completed requests.
    pub const fn requests(&self) -> RequestCount {
        self.requests
    }

    /// Input tokens recorded.
    pub const fn tokens_in(&self) -> Option<TokenCount> {
        self.tokens_in
    }

    /// Output tokens recorded.
    pub const fn tokens_out(&self) -> Option<TokenCount> {
        self.tokens_out
    }
}

/// Evidence of an atomically committed session restoration.
#[derive(Clone, Debug, Serialize)]
pub struct RestoreReceipt {
    session_id: SessionId,
    mode: Mode,
    history_revision: HistoryRevision,
    selection_revision: SelectionRevision,
    mode_revision: ModeRevision,
    sequence: SessionEventSequence,
    accounting: SessionAccounting,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_root: Option<PathBuf>,
}

impl RestoreReceipt {
    /// Session identifier.
    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    /// Mode active after restore.
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// History revision.
    pub fn history_revision(&self) -> HistoryRevision {
        self.history_revision
    }

    /// Selection revision.
    pub fn selection_revision(&self) -> SelectionRevision {
        self.selection_revision
    }

    /// Mode revision.
    pub fn mode_revision(&self) -> ModeRevision {
        self.mode_revision
    }

    /// Event sequence.
    pub fn sequence(&self) -> SessionEventSequence {
        self.sequence
    }

    /// Accounting snapshot.
    pub fn accounting(&self) -> &SessionAccounting {
        &self.accounting
    }

    /// Project root path.
    pub fn project_root(&self) -> Option<&Path> {
        self.project_root.as_deref()
    }

    /// Convert into JSON Value.
    pub fn into_json(self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or(serde_json::Value::Null)
    }
}

/// A strictly validated candidate ready for single-transaction atomic restore.
pub struct RestoreCandidate {
    history: History,
    selection: Selection,
    mode: Mode,
    accounting: SessionAccounting,
    project_root: Option<PathBuf>,
    transcript: Option<String>,
    title: Option<String>,
}

impl RestoreCandidate {
    /// Build candidate from validated session record and optional expected project root.
    pub fn from_record(
        record: &SessionRecord,
        expected_root: Option<&Path>,
    ) -> Result<Self, CoreError> {
        let project_root = check_root_compatibility(record.project_root(), expected_root)?;
        let selection = build_selection(record)?;
        let mode = build_mode(record)?;
        let accounting = build_accounting(record);
        let history = build_history(record)?;
        let transcript = record.transcript().map(|t| t.as_str().to_owned());
        let title = record.title().map(|t| t.as_str().to_owned());
        Ok(Self {
            history,
            selection,
            mode,
            accounting,
            project_root,
            transcript,
            title,
        })
    }

    /// Parse, migrate if necessary, and validate candidate from JSON payload.
    pub fn from_json(
        val: &serde_json::Value,
        expected_root: Option<&Path>,
    ) -> Result<Self, CoreError> {
        let payload = RawSessionPayload::try_from(val.to_string())
            .map_err(|_| CoreError::InvalidValue { field: "candidate" })?;
        let migrated = migrate_candidate(&payload, &CollisionPolicy::Reject)
            .map_err(|_| CoreError::InvalidValue { field: "candidate" })?;
        Self::from_record(migrated.record(), expected_root)
    }

    /// Borrow history.
    pub fn history(&self) -> &History {
        &self.history
    }

    /// Borrow selection.
    pub fn selection(&self) -> &Selection {
        &self.selection
    }

    /// Borrow mode.
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// Borrow accounting.
    pub fn accounting(&self) -> &SessionAccounting {
        &self.accounting
    }

    /// Borrow project root.
    pub fn project_root(&self) -> Option<&Path> {
        self.project_root.as_deref()
    }
}

struct RestoredState {
    history: History,
    selection: Selection,
}

struct RestoredMeta {
    mode: Mode,
    history_rev: HistoryRevision,
    selection_rev: SelectionRevision,
    accounting: SessionAccounting,
    transcript: Option<String>,
    title: Option<String>,
    project_root: Option<PathBuf>,
}

impl ApplicationActor {
    /// Context root path associated with conversation.
    pub fn session_root(&self, session: &SessionId) -> Option<&Path> {
        self.session_roots.get(session).map(PathBuf::as_path)
    }

    /// Recorded accounting usage counters.
    pub fn session_accounting(&self, session: &SessionId) -> Option<&SessionAccounting> {
        self.session_accounting.get(session)
    }

    fn check_session_idle(&self, session: &SessionId) -> Result<(), CoreError> {
        if self.active.is_some() || self.preparing.is_some() {
            return Err(CoreError::Busy);
        }
        if self
            .job_runs
            .values()
            .chain(self.editor_runs.values())
            .any(|run| run.handle.scope().session_id() == session)
        {
            return Err(CoreError::Busy);
        }
        Ok(())
    }

    fn apply_restored_state(
        &mut self,
        session: &SessionId,
        state: RestoredState,
    ) -> (HistoryRevision, SelectionRevision) {
        let history_rev = state.history.revision();
        self.histories.insert(session.clone(), state.history);
        let store = SessionSelection::from_selection(state.selection);
        let selection_rev = store.revision();
        self.selections.insert(session.clone(), store);
        (history_rev, selection_rev)
    }

    fn apply_restored_meta(
        &mut self,
        session: &SessionId,
        meta: RestoredMeta,
    ) -> Result<RestoreReceipt, CoreError> {
        let mode_store = SessionMode::with_mode(meta.mode);
        let mode_rev = mode_store.revision();
        self.modes.insert(session.clone(), mode_store);
        if let Some(root) = meta.project_root {
            self.session_roots.insert(session.clone(), root);
        }
        self.session_accounting
            .insert(session.clone(), meta.accounting);
        self.plans.remove(session);
        let sequence = self.next_session_event(session)?;
        Ok(RestoreReceipt {
            session_id: session.clone(),
            mode: meta.mode,
            history_revision: meta.history_rev,
            selection_revision: meta.selection_rev,
            mode_revision: mode_rev,
            sequence,
            accounting: meta.accounting,
            transcript: meta.transcript,
            title: meta.title,
            project_root: self.session_roots.get(session).cloned(),
        })
    }

    /// Atomically restore a validated candidate session into an owned idle session.
    pub fn restore_session(
        &mut self,
        session: &SessionId,
        candidate: RestoreCandidate,
    ) -> Result<RestoreReceipt, CoreError> {
        if !self.owns_session(session) {
            return Err(CoreError::StaleOwner);
        }
        self.check_session_idle(session)?;
        self.check_history_capacity(session, candidate.history().accounted_bytes())?;
        let state = RestoredState {
            history: candidate.history,
            selection: candidate.selection,
        };
        let (history_rev, selection_rev) = self.apply_restored_state(session, state);
        let meta = RestoredMeta {
            mode: candidate.mode,
            history_rev,
            selection_rev,
            accounting: candidate.accounting,
            transcript: candidate.transcript,
            title: candidate.title,
            project_root: candidate.project_root,
        };
        self.apply_restored_meta(session, meta)
    }
}

fn check_root_compatibility(
    candidate_root: Option<&Path>,
    expected_root: Option<&Path>,
) -> Result<Option<PathBuf>, CoreError> {
    match (candidate_root, expected_root) {
        (Some(c), Some(e)) => {
            let c_canon = c.canonicalize().unwrap_or_else(|_| c.to_path_buf());
            let e_canon = e.canonicalize().unwrap_or_else(|_| e.to_path_buf());
            if c_canon != e_canon {
                return Err(CoreError::WorkspaceChanged);
            }
            Ok(Some(e_canon))
        }
        (None, Some(e)) => Ok(Some(e.canonicalize().unwrap_or_else(|_| e.to_path_buf()))),
        (Some(c), None) => Ok(Some(c.canonicalize().unwrap_or_else(|_| c.to_path_buf()))),
        (None, None) => Ok(None),
    }
}

fn convert_session_message(msg: &SessionMessage) -> Result<Message, CoreError> {
    let raw = serde_json::value::to_raw_value(msg)
        .map_err(|_| CoreError::History(HistoryError::InvalidMessage))?;
    Message::try_from(raw).map_err(CoreError::from)
}

fn build_history(record: &SessionRecord) -> Result<History, CoreError> {
    let mut messages = Vec::with_capacity(record.messages().len());
    for msg in record.messages() {
        messages.push(convert_session_message(msg)?);
    }
    History::import(messages).map_err(CoreError::from)
}

fn build_provider(record: &SessionRecord) -> Result<Option<ApiProviderId>, CoreError> {
    record
        .provider()
        .map(|p| ApiProviderId::try_from(p.as_str().to_owned()))
        .transpose()
}

fn build_model(record: &SessionRecord) -> Result<Option<ModelChoice>, CoreError> {
    record
        .model()
        .map(|m| ModelChoice::try_from(m.as_str().to_owned()))
        .transpose()
}

fn build_effort(record: &SessionRecord) -> Result<EffortChoice, CoreError> {
    match record.effort() {
        Some(SessionEffort::Inherit) | None => Ok(EffortChoice::Inherit),
        Some(SessionEffort::Off) => Ok(EffortChoice::Off),
        Some(SessionEffort::Value { value }) => {
            let label = EffortLabel::try_from(value.clone())?;
            Ok(EffortChoice::Named { name: label })
        }
    }
}

fn build_selection(record: &SessionRecord) -> Result<Selection, CoreError> {
    let provider = build_provider(record)?;
    let model = build_model(record)?;
    let effort = build_effort(record)?;
    Ok(Selection::new(provider, model, effort))
}

fn build_mode(record: &SessionRecord) -> Result<Mode, CoreError> {
    match record.mode().map(|m| m.as_str()) {
        None | Some("ask") => Ok(Mode::Ask),
        Some("plan") => Ok(Mode::Plan),
        Some("agent") => Ok(Mode::Agent),
        Some("debug") => Ok(Mode::Debug),
        Some(_) => Err(CoreError::InvalidValue { field: "mode" }),
    }
}

fn build_accounting(record: &SessionRecord) -> SessionAccounting {
    SessionAccounting::new(
        record.requests().unwrap_or(RequestCount::ZERO),
        record.tokens_in(),
        record.tokens_out(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ApplicationId;
    use serde_json::json;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn restore_from_v2_and_legacy_json() -> TestResult {
        let v2_json = json!({
            "schema_version": 2,
            "id": "test-v2",
            "mode": "plan",
            "provider": "open_ai",
            "model": "gpt-4o",
            "effort": {"kind": "off"},
            "tokens_in": 100,
            "tokens_out": 50,
            "requests": 3,
            "project_root": "/workspace/test",
            "transcript": "Test transcript",
            "messages": [
                {"role": "user", "content": "Hello"}
            ]
        });

        let cand = RestoreCandidate::from_json(&v2_json, None)?;
        assert_eq!(cand.mode(), Mode::Plan);
        assert_eq!(cand.accounting().requests().as_u64(), 3);
        assert_eq!(cand.history().snapshot().len(), 1);

        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let receipt = actor.restore_session(&session, cand)?;
        assert_eq!(receipt.mode(), Mode::Plan);
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Plan);

        let legacy_json = json!({
            "id": "test-legacy",
            "mode": "ask",
            "messages": [
                {"role": "user", "content": "Legacy hi"}
            ]
        });
        let legacy_cand = RestoreCandidate::from_json(&legacy_json, None)?;
        let receipt2 = actor.restore_session(&session, legacy_cand)?;
        assert_eq!(receipt2.mode(), Mode::Ask);
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Ask);
        Ok(())
    }

    #[test]
    fn corrupted_candidate_preserves_old_session_completely() -> TestResult {
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();

        let good_json = json!({
            "schema_version": 2,
            "id": "good-session",
            "mode": "plan",
            "messages": [{"role": "user", "content": "Original message"}]
        });
        let good_cand = RestoreCandidate::from_json(&good_json, None)?;
        actor.restore_session(&session, good_cand)?;
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Plan);
        let orig_history_len = actor.session_history(&session)?.snapshot().len();
        assert_eq!(orig_history_len, 1);

        // Attempt 1: Corrupted message (tool message without tool_call_id)
        let bad_msg_json = json!({
            "schema_version": 2,
            "id": "bad-session",
            "mode": "agent",
            "messages": [{"role": "tool", "content": "orphan tool"}]
        });
        assert!(RestoreCandidate::from_json(&bad_msg_json, None).is_err());
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Plan);
        assert_eq!(actor.session_history(&session)?.snapshot().len(), 1);

        // Attempt 2: Invalid model name
        let bad_model_json = json!({
            "schema_version": 2,
            "id": "bad-session",
            "mode": "agent",
            "model": "invalid\x00control",
            "messages": []
        });
        assert!(RestoreCandidate::from_json(&bad_model_json, None).is_err());
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Plan);

        // Attempt 3: Root mismatch
        let root_json = json!({
            "schema_version": 2,
            "id": "root-session",
            "mode": "agent",
            "project_root": "/project/alpha",
            "messages": []
        });
        assert!(RestoreCandidate::from_json(&root_json, Some(Path::new("/project/beta"))).is_err());
        assert_eq!(actor.session_mode(&session)?.mode(), Mode::Plan);
        Ok(())
    }

    #[test]
    fn restore_rejected_when_active_run_in_flight() -> TestResult {
        use crate::domain::{ConfigRevision, PolicyRevision, ToolCallLimit};
        use crate::policy::Workspace;
        use std::time::Duration;

        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();

        let tmp = tempfile::tempdir()?;
        let workspace = Workspace::try_from(tmp.path().to_path_buf())?;
        let settings = crate::application::RunSettings::new(
            Mode::Ask,
            workspace,
            ToolCallLimit::default(),
            Duration::from_secs(60),
            ConfigRevision::ZERO,
            PolicyRevision::ZERO,
        )?;

        let _handle = actor.admit(&session, settings)?;

        let candidate_json = json!({
            "schema_version": 2,
            "id": "test-busy",
            "mode": "plan",
            "messages": []
        });
        let cand = RestoreCandidate::from_json(&candidate_json, None)?;
        let res = actor.restore_session(&session, cand);
        assert!(matches!(res, Err(CoreError::Busy)));
        Ok(())
    }
}
