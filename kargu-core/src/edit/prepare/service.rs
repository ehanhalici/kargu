//! One application-actor writer owns upload/adoption/expiry. Workers own only input.
use super::{
    Artifact, ClaimWork, PartBuffer, PreparationResult, Work,
    inspection::{Inspection, PatchWork, PrepareWork},
    types::{self, Begin, Intent, OriginId, Part, PreparationId},
};
use crate::{
    constants::{limits, protocol::methods, timeouts},
    domain::Mode,
    domain::rpc::Fault,
    domain::{ByteLimit, SessionId},
    edit::EditError,
    error::CoreError,
};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::Arc,
    time::Instant,
};

#[derive(Clone, Copy)]
struct Reservation(usize);
struct Owner {
    session: SessionId,
    origin: OriginId,
    service_id: Option<crate::domain::EditServiceId>,
}
struct Entry {
    owner: Owner,
    reserved: Reservation,
    expires: Instant,
    phase: Phase,
    provenance: Provenance,
}
enum Provenance {
    Forward,
    Rollback {
        target: crate::edit::types::EditorEditId,
        files: Vec<super::types::FileIndex>,
    },
}
enum Phase {
    Uploading {
        input: Box<Begin>,
        parts: BTreeMap<Part, PartBuffer>,
    },
    Preparing {
        revoked: bool,
    },
    Collecting(Box<Inspection>),
    Ready(Box<Artifact>),
    Claimed {
        artifact: Arc<Artifact>,
        revoked: bool,
    },
}
#[derive(Clone, Copy, Eq, PartialEq)]
enum ServiceState {
    Open,
    Closed,
}
/// Actor-only store. The separate states never contain optional worker handles.
#[derive(Default)]
pub(crate) struct EditPreparations {
    entries: HashMap<PreparationId, Entry>,
    snapshots: VecDeque<super::AppliedSnapshot>,
    changes: VecDeque<super::history::ChangedFileRecord>,
    history_revision: super::history::HistoryRevision,
    // Closed identities remain tombstoned for the lifetime of their session;
    // delayed preparation or actual receipts cannot revive a retired service.
    services: HashMap<(SessionId, crate::domain::EditServiceId), ServiceState>,
    parents: HashMap<(SessionId, OriginId), super::parent::ParentSource>,
}
fn decode<T: DeserializeOwned>(value: Value) -> Result<T, CoreError> {
    serde_json::from_value(value).map_err(|_| EditError::InvalidEvidence.into())
}
impl Owner {
    fn matches(&self, session: &SessionId, origin: &OriginId) -> bool {
        &self.session == session && &self.origin == origin
    }
}
impl EditPreparations {
    pub(crate) fn conversation_changes(
        &self,
        session: &SessionId,
    ) -> Result<super::history::ChangeSummary, CoreError> {
        super::history::ChangeSummary::capture(session, self.history_revision, &self.changes)
    }
    pub(crate) fn capture_verification(
        &self,
        session: &SessionId,
        root: &std::path::Path,
        document: &crate::sensors::diagnostics::DocumentStamp,
    ) -> Option<super::VerificationTicket> {
        super::verification::capture(&self.changes, session, root, document)
    }
    pub(crate) fn settle_verification(
        &mut self,
        session: &SessionId,
        ticket: super::VerificationTicket,
        snapshot: &crate::sensors::diagnostics::DiagnosticSnapshot,
    ) -> Result<bool, CoreError> {
        super::verification::settle(
            &mut self.changes,
            &mut self.history_revision,
            session,
            ticket,
            snapshot,
        )
    }
    pub(crate) fn register_parent(
        &mut self,
        source: OriginId,
        call: super::ParentCall,
        policy: super::ParentPolicy,
        selection: Option<crate::sensors::symbols::SymbolEditSelection>,
    ) -> Result<(), CoreError> {
        let binding = super::ParentEdit::capture(call, policy, selection)?;
        let key = (binding.run.scope().session_id().clone(), source);
        if self.parents.contains_key(&key)
            || self.parents.len() >= limits::HISTORY_CALLS
            || self
                .entries
                .values()
                .any(|entry| entry.owner.matches(&key.0, &key.1))
        {
            return Err(CoreError::Limit);
        }
        self.parents.insert(
            key,
            super::parent::ParentSource {
                state: super::parent::ParentState::Open {
                    binding: Box::new(binding),
                    begun: false,
                },
                step: None,
                result: None,
            },
        );
        Ok(())
    }
    fn parent(
        &self,
        session: &SessionId,
        origin: &OriginId,
    ) -> Result<Option<super::ParentEdit>, CoreError> {
        match self.parents.get(&(session.clone(), origin.clone())) {
            None => Ok(None),
            Some(source) => match &source.state {
                super::parent::ParentState::Open { binding, .. } => {
                    binding.run.check_live()?;
                    Ok(Some((**binding).clone()))
                }
                super::parent::ParentState::Closed => Err(CoreError::Cancelled),
            },
        }
    }
    pub(crate) fn record_parent_step(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        step: crate::domain::ToolStepId,
    ) -> Result<(), CoreError> {
        let source = self
            .parents
            .get_mut(&(session.clone(), origin.clone()))
            .ok_or(CoreError::StaleOwner)?;
        if !matches!(source.state, super::parent::ParentState::Open { .. }) || source.step.is_some()
        {
            return Err(CoreError::AlreadyCompleted);
        }
        source.step = Some(step);
        Ok(())
    }
    pub(crate) fn parent_step(
        &self,
        session: &SessionId,
        origin: &OriginId,
    ) -> Option<&crate::domain::ToolStepId> {
        self.parents
            .get(&(session.clone(), origin.clone()))
            .and_then(|source| source.step.as_ref())
    }
    pub(crate) fn record_parent_result(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        result: super::ParentResult,
    ) {
        if let Some(source) = self.parents.get_mut(&(session.clone(), origin.clone())) {
            source.result = Some(result);
        }
    }
    pub(crate) fn take_parent_result(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
    ) -> Option<super::ParentResult> {
        self.parents
            .get_mut(&(session.clone(), origin.clone()))
            .and_then(|source| source.result.take())
    }
    pub(crate) fn close_parent(&mut self, session: &SessionId, origin: &OriginId) {
        if let Some(source) = self.parents.get_mut(&(session.clone(), origin.clone())) {
            source.state = super::parent::ParentState::Closed;
        }
        self.entries.retain(|_, entry| {
            if !entry.owner.matches(session, origin) {
                return true;
            }
            match &mut entry.phase {
                Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                    *revoked = true;
                    true
                }
                _ => false,
            }
        });
    }
    pub(crate) fn parent_busy(&self, session: &SessionId, origin: &OriginId) -> bool {
        self.entries
            .values()
            .any(|entry| entry.owner.matches(session, origin))
    }
    pub(crate) fn sweep(&mut self, now: Instant) {
        self.entries.retain(|_, entry| {
            if now < entry.expires {
                return true;
            }
            match &mut entry.phase {
                Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                    *revoked = true;
                    true
                }
                _ => false,
            }
        });
    }
    pub(crate) fn close_session(&mut self, session: &SessionId) {
        // Actual issued receipts may arrive while this closed session drains.
        // Keep their small outcome/step records until the owning call collects
        // them; drop captured arguments and prevent every fresh preparation.
        for ((owner, _), source) in &mut self.parents {
            if owner == session {
                source.state = super::parent::ParentState::Closed;
            }
        }
        self.services.retain(|(owner, _), _| owner != session);
        self.snapshots
            .retain(|snapshot| &snapshot.session != session);
        self.changes.retain(|record| &record.session != session);
        self.entries.retain(|_, entry| {
            if &entry.owner.session != session {
                return true;
            }
            match &mut entry.phase {
                Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                    *revoked = true;
                    true
                }
                _ => false,
            }
        });
    }
    pub(crate) fn close_service(
        &mut self,
        session: &SessionId,
        service_id: &crate::domain::EditServiceId,
    ) -> Result<Value, CoreError> {
        let key = (session.clone(), service_id.clone());
        if !self.services.contains_key(&key) && self.services.len() >= limits::EDIT_SERVICES {
            return Err(CoreError::Limit);
        }
        self.services.insert(key, ServiceState::Closed);
        let mut changed = false;
        let before_snapshots = self.snapshots.len();
        self.snapshots.retain(|snapshot| {
            !(&snapshot.session == session && snapshot.service_id.as_ref() == Some(service_id))
        });
        if self.snapshots.len() != before_snapshots {
            changed = true;
        }
        let before_changes = self.changes.len();
        self.changes.retain(|record| {
            !(&record.session == session && record.service_id.as_ref() == Some(service_id))
        });
        if self.changes.len() != before_changes {
            changed = true;
        }
        self.entries.retain(|_, entry| {
            if !(&entry.owner.session == session
                && entry.owner.service_id.as_ref() == Some(service_id))
            {
                return true;
            }
            match &mut entry.phase {
                Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                    changed |= !*revoked;
                    *revoked = true;
                    true
                }
                _ => {
                    changed = true;
                    false
                }
            }
        });
        if changed {
            self.history_revision.advance()?;
        }
        Ok(json!({
            "closed": true,
            "drained": !self.entries.values().any(|entry|
                &entry.owner.session == session && entry.owner.service_id.as_ref() == Some(service_id)),
            "revision": self.history_revision,
        }))
    }

    fn admit_service(
        &mut self,
        session: &SessionId,
        service: Option<&crate::domain::EditServiceId>,
    ) -> Result<(), CoreError> {
        if let Some(service) = service {
            let key = (session.clone(), service.clone());
            if self.services.get(&key) == Some(&ServiceState::Closed) {
                return Err(CoreError::Cancelled);
            }
            if !self.services.contains_key(&key) && self.services.len() >= limits::EDIT_SERVICES {
                return Err(CoreError::Limit);
            }
            self.services.entry(key).or_insert(ServiceState::Open);
        }
        Ok(())
    }
    pub(crate) fn revoke(&mut self) {
        for source in self.parents.values_mut() {
            source.state = super::parent::ParentState::Closed;
        }
        self.entries.retain(|_, entry| match &mut entry.phase {
            Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                *revoked = true;
                true
            }
            _ => false,
        });
    }
    pub(crate) fn rpc(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: Value,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, Fault> {
        self.sweep(now);
        self.call(session, method, arguments, frame, now)
            .map_err(super::fault)
    }
    fn call(
        &mut self,
        session: &SessionId,
        method: &str,
        args: Value,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        match method {
            methods::EDIT_HISTORY => {
                let query: super::history::HistoryQuery = decode(args)?;
                if let super::history::HistoryQuery::CloseService { service_id } = query {
                    return self.close_service(session, &service_id);
                }
                super::history::execute(
                    &mut self.snapshots,
                    &mut self.changes,
                    session,
                    &mut self.history_revision,
                    query,
                    frame,
                )
            }
            methods::EDIT_BEGIN => self.begin(session, decode(args)?, frame, now),
            methods::EDIT_APPEND => {
                let input: types::Append = decode(args)?;
                let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
                let parts = match &mut entry.phase {
                    Phase::Uploading { parts, .. } => parts,
                    Phase::Collecting(patch) => &mut patch.parts,
                    _ => return Err(CoreError::AlreadyCompleted),
                };
                parts
                    .get_mut(&input.part)
                    .ok_or(EditError::InvalidEvidence)?
                    .append(input.offset, &input.text.0)?;
                Ok(
                    json!({"offset":parts.get(&input.part).ok_or(EditError::InvalidEvidence)?.text.len()}),
                )
            }
            methods::EDIT_READ => {
                let input: types::Read = decode(args)?;
                let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
                match &entry.phase {
                    Phase::Ready(artifact) => {
                        artifact.page(input.file, input.part, input.offset, frame)
                    }
                    Phase::Claimed { artifact, .. } => {
                        artifact.page(input.file, input.part, input.offset, frame)
                    }
                    _ => Err(CoreError::AlreadyCompleted),
                }
            }
            methods::EDIT_TARGETS | methods::EDIT_FILES => {
                let input: types::Targets = decode(args)?;
                let entry = self.owned(session, input.origin_id(), input.preparation_id())?;
                match (&entry.phase, method) {
                    (Phase::Collecting(patch), methods::EDIT_TARGETS) => {
                        patch.targets(input.offset, frame)
                    }
                    (Phase::Ready(artifact), methods::EDIT_FILES) => {
                        artifact.files(input.preparation_id(), input.offset, frame)
                    }
                    (Phase::Claimed { artifact, .. }, methods::EDIT_FILES) => {
                        artifact.files(input.preparation_id(), input.offset, frame)
                    }
                    _ => Err(CoreError::AlreadyCompleted),
                }
            }
            methods::EDIT_DOCUMENT => {
                let input: types::Document = decode(args)?;
                let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
                let Phase::Collecting(patch) = &mut entry.phase else {
                    return Err(CoreError::AlreadyCompleted);
                };
                patch.document(input)
            }
            methods::EDIT_ABORT => {
                let input: types::Ticket = decode(args)?;
                let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
                if let Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } =
                    &mut entry.phase
                {
                    *revoked = true;
                } else {
                    self.entries.remove(&input.preparation_id);
                }
                Ok(json!({"aborted":true}))
            }
            methods::EDIT_CLOSE => {
                let input: types::Close = decode(args)?;
                self.entries.retain(|_, entry| {
                    if !entry.owner.matches(session, input.origin_id()) {
                        return true;
                    }
                    match &mut entry.phase {
                        Phase::Preparing { revoked } | Phase::Claimed { revoked, .. } => {
                            *revoked = true;
                            true
                        }
                        _ => false,
                    }
                });
                Ok(json!({"closed":true}))
            }
            _ => Err(CoreError::Unavailable),
        }
    }
    fn begin(
        &mut self,
        session: &SessionId,
        input: Begin,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        if input.mode != Mode::Agent {
            return Err(CoreError::Rejected);
        }
        let parent = self.parent(session, &input.origin_id)?;
        if let Some(parent) = &parent {
            parent.check_begin(&input)?;
            if !matches!(
                self.parents
                    .get(&(session.clone(), input.origin_id.clone()))
                    .map(|source| &source.state),
                Some(super::parent::ParentState::Open { begun: false, .. })
            ) {
                return Err(CoreError::AlreadyCompleted);
            }
        }
        crate::workspace::command::validate_path(&input.root)?;
        if !input.root.is_absolute() || input.root.as_os_str().as_encoded_bytes().contains(&0) {
            return Err(EditError::InvalidPath.into());
        }
        if input
            .live
            .as_ref()
            .is_some_and(|live| live.dirty || live.read_only)
        {
            return Err(EditError::Conflict.into());
        }
        if matches!(input.intent, Intent::Symbol { .. })
            && (parent.is_none() || input.live.is_none())
        {
            return Err(CoreError::Rejected);
        }
        let mut parts = BTreeMap::new();
        let mut extra = if input.live.is_some() {
            0
        } else {
            limits::EDIT_TEXT_BYTES
        };
        match &input.intent {
            Intent::Replace {
                old_bytes,
                new_bytes,
                ..
            } => {
                if old_bytes.get() == 0 {
                    return Err(EditError::MissingMatch.into());
                }
                parts.insert(Part::Old, PartBuffer::new(*old_bytes));
                parts.insert(Part::New, PartBuffer::new(*new_bytes));
                extra = extra
                    .checked_add(limits::EDIT_TEXT_BYTES)
                    .ok_or(EditError::Limit)?;
            }
            Intent::Patch { patch_bytes } => {
                if input.live.is_some() {
                    return Err(EditError::InvalidEvidence.into());
                }
                parts.insert(Part::Patch, PartBuffer::new(*patch_bytes));
                extra = 0;
            }
            Intent::Write { new_bytes, .. } | Intent::Symbol { new_bytes, .. } => {
                parts.insert(Part::New, PartBuffer::new(*new_bytes));
            }
        }
        if let Some(live) = &input.live {
            parts.insert(Part::Document, PartBuffer::new(live.bytes));
        }
        let mut reserved = Reservation(parts.values().try_fold(extra, |n, p| {
            n.checked_add(p.expected.get()).ok_or(EditError::Limit)
        })?);
        if matches!(input.intent, Intent::Patch { .. }) {
            reserved = Reservation(limits::EDIT_BUFFER_BYTES);
        }
        let total = self.entries.values().try_fold(reserved.0, |n, e| {
            n.checked_add(e.reserved.0).ok_or(EditError::Limit)
        })?;
        if self.entries.len() >= limits::EDIT_PREPARATIONS || total > limits::EDIT_BUFFER_BYTES {
            return Err(CoreError::Limit);
        }
        let id = PreparationId::new();
        let expires = now
            .checked_add(timeouts::WORKSPACE_READ)
            .ok_or(CoreError::ArithmeticOverflow)?;
        let expires = parent
            .as_ref()
            .map_or(expires, |parent| parent.deadline(expires));
        let part_info: Vec<_> = parts
            .iter()
            .map(|(name, value)| json!({"part":name,"bytes":value.expected}))
            .collect();
        self.admit_service(session, input.service_id.as_ref())?;
        if let Some(source) = self
            .parents
            .get_mut(&(session.clone(), input.origin_id.clone()))
            && let super::parent::ParentState::Open { begun, .. } = &mut source.state
        {
            *begun = true;
        }
        self.entries.insert(
            id.clone(),
            Entry {
                provenance: Provenance::Forward,
                owner: Owner {
                    session: session.clone(),
                    origin: input.origin_id.clone(),
                    service_id: input.service_id.clone(),
                },
                reserved,
                expires,
                phase: Phase::Uploading {
                    input: Box::new(input),
                    parts,
                },
            },
        );
        Ok(
            json!({"preparation_id":id,"parts":part_info,"page_bytes":limits::EDIT_PAGE_BYTES.min(frame.as_usize().saturating_sub(512)/6)}),
        )
    }
    fn owned(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        id: &PreparationId,
    ) -> Result<&mut Entry, CoreError> {
        let entry = self.entries.get_mut(id).ok_or(CoreError::StaleOwner)?;
        if !entry.owner.matches(session, origin) {
            return Err(CoreError::StaleOwner);
        }
        if matches!(
            entry.phase,
            Phase::Preparing { revoked: true } | Phase::Claimed { revoked: true, .. }
        ) {
            return Err(CoreError::Cancelled);
        }
        Ok(entry)
    }
    pub(crate) fn take(
        &mut self,
        session: &SessionId,
        args: Value,
        now: Instant,
        inspect: bool,
    ) -> Result<PrepareWork, Fault> {
        self.sweep(now);
        self.take_inner(session, args, inspect)
            .map_err(super::fault)
    }
    fn take_inner(
        &mut self,
        session: &SessionId,
        args: Value,
        inspect: bool,
    ) -> Result<PrepareWork, CoreError> {
        let input: types::Ticket = decode(args)?;
        let parent = self.parent(session, &input.origin_id)?;
        let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
        let valid = match &entry.phase {
            Phase::Uploading { input, parts } => {
                matches!(input.intent, Intent::Patch { .. }) == inspect
                    && parts.values().all(PartBuffer::complete)
            }
            Phase::Collecting(patch) => !inspect && patch.parts.values().all(PartBuffer::complete),
            _ => false,
        };
        if !valid {
            return Err(EditError::InvalidEvidence.into());
        }
        let phase = std::mem::replace(&mut entry.phase, Phase::Preparing { revoked: false });
        match phase {
            Phase::Uploading {
                input: begin,
                parts,
            } => Ok(PrepareWork::Read(Work {
                id: input.preparation_id,
                input: *begin,
                parts,
                deadline: entry.expires,
                parent,
            })),
            Phase::Collecting(patch) => Ok(PrepareWork::Patch(PatchWork {
                id: input.preparation_id,
                inspection: *patch,
                deadline: entry.expires,
                parent,
            })),
            _ => Err(CoreError::CleanupFailed),
        }
    }
    pub(crate) fn claim(
        &mut self,
        session: &SessionId,
        args: Value,
        now: Instant,
    ) -> Result<ClaimWork, CoreError> {
        self.sweep(now);
        let input: types::Ticket = decode(args)?;
        let parent = self.parent(session, &input.origin_id)?;
        self.owned(session, &input.origin_id, &input.preparation_id)?;
        let entry = self
            .entries
            .get(&input.preparation_id)
            .ok_or(CoreError::StaleOwner)?;
        let Phase::Ready(artifact) = &entry.phase else {
            return Err(CoreError::AlreadyCompleted);
        };
        self.check_change_capacity(&entry.owner, artifact)?;
        let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
        let phase = std::mem::replace(&mut entry.phase, Phase::Preparing { revoked: false });
        let Phase::Ready(artifact) = phase else {
            return Err(CoreError::CleanupFailed);
        };
        let artifact = Arc::new(*artifact);
        entry.phase = Phase::Claimed {
            artifact: artifact.clone(),
            revoked: false,
        };
        Ok(ClaimWork {
            id: input.preparation_id,
            origin: input.origin_id,
            artifact,
            deadline: entry.expires,
            parent,
        })
    }
    fn check_change_capacity(
        &self,
        incoming: &Owner,
        artifact: &Artifact,
    ) -> Result<(), CoreError> {
        let mut reserved = super::history::ChangeReservations::default();
        for record in self.changes.iter().filter(|row| row.verification_pending) {
            reserved.change(record)?;
        }
        for entry in self.entries.values() {
            if let Phase::Claimed { artifact, .. } = &entry.phase {
                reserved.artifact(&entry.owner.session, &entry.owner.service_id, artifact)?;
            }
        }
        reserved.artifact(&incoming.session, &incoming.service_id, artifact)
    }
    pub(crate) fn claim_status(
        &self,
        session: &SessionId,
        id: &PreparationId,
        now: Instant,
    ) -> Result<(), CoreError> {
        let entry = self.entries.get(id).ok_or(CoreError::StaleOwner)?;
        if &entry.owner.session != session {
            return Err(CoreError::StaleOwner);
        }
        if now >= entry.expires {
            return Err(CoreError::Deadline);
        }
        match entry.phase {
            Phase::Claimed { revoked: false, .. } => Ok(()),
            Phase::Claimed { revoked: true, .. } => Err(CoreError::Cancelled),
            _ => Err(CoreError::StaleOwner),
        }
    }
    pub(crate) fn claimed_artifact(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        id: &PreparationId,
        now: Instant,
    ) -> Result<Arc<Artifact>, CoreError> {
        self.claim_status(session, id, now)?;
        let entry = self.owned(session, origin, id)?;
        let Phase::Claimed { artifact, .. } = &entry.phase else {
            return Err(CoreError::StaleOwner);
        };
        Ok(artifact.clone())
    }
    pub(crate) fn release_claim(
        &mut self,
        session: &SessionId,
        id: &PreparationId,
    ) -> Result<(), CoreError> {
        let entry = self.entries.get(id).ok_or(CoreError::StaleOwner)?;
        if &entry.owner.session != session || !matches!(entry.phase, Phase::Claimed { .. }) {
            return Err(CoreError::StaleOwner);
        }
        self.entries.remove(id);
        Ok(())
    }
    pub(crate) fn reserve_revision(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        id: &PreparationId,
        extra: super::types::TextOffset,
    ) -> Result<Arc<Artifact>, CoreError> {
        let total = self.entries.values().try_fold(extra.get(), |n, entry| {
            n.checked_add(entry.reserved.0).ok_or(CoreError::Limit)
        })?;
        if total > limits::EDIT_BUFFER_BYTES {
            return Err(CoreError::Limit);
        }
        let entry = self.owned(session, origin, id)?;
        let Phase::Claimed {
            artifact,
            revoked: false,
        } = &entry.phase
        else {
            return Err(CoreError::StaleOwner);
        };
        entry.reserved = Reservation(
            entry
                .reserved
                .0
                .checked_add(extra.get())
                .ok_or(CoreError::Limit)?,
        );
        Ok(artifact.clone())
    }
    pub(crate) fn finish_revision(
        &mut self,
        session: &SessionId,
        origin: &OriginId,
        id: &PreparationId,
        candidate: Option<Artifact>,
    ) -> Result<(), CoreError> {
        let entry = self.entries.get_mut(id).ok_or(CoreError::StaleOwner)?;
        if !entry.owner.matches(session, origin) {
            return Err(CoreError::StaleOwner);
        }
        let Phase::Claimed { artifact, revoked } = &mut entry.phase else {
            return Err(CoreError::StaleOwner);
        };
        if let Some(candidate) = candidate {
            if *revoked || Instant::now() >= entry.expires {
                return Err(CoreError::Cancelled);
            }
            let bytes = candidate.retained_bytes()?.get();
            if bytes > entry.reserved.0 {
                return Err(CoreError::Limit);
            }
            *artifact = Arc::new(candidate);
        }
        entry.reserved = Reservation(artifact.retained_bytes()?.get());
        Ok(())
    }
    pub(crate) fn record_applied(
        &mut self,
        session: &SessionId,
        edit_id: &crate::edit::types::EditorEditId,
        preparation: &PreparationId,
        receipt: &super::receipt::VerifiedReceipt,
    ) -> Result<super::AppliedPublication, CoreError> {
        let entry = self.entries.get(preparation).ok_or(CoreError::StaleOwner)?;
        if &entry.owner.session != session {
            return Err(CoreError::StaleOwner);
        }
        let Phase::Claimed { artifact, .. } = &entry.phase else {
            return Err(CoreError::StaleOwner);
        };
        let service_id = entry.owner.service_id.clone();
        if service_id.as_ref().is_some_and(|service| {
            self.services.get(&(session.clone(), service.clone())) == Some(&ServiceState::Closed)
        }) {
            return Ok(super::AppliedPublication::default());
        }
        self.history_revision.advance()?;
        let revision = self.history_revision;
        if let Provenance::Rollback { target, files } = &entry.provenance {
            let mut completed = Vec::new();
            for result in receipt
                .files()
                .iter()
                .filter(|r| r.outcome() == super::receipt::FileOutcome::Applied)
            {
                let original = *files
                    .get(result.index().get())
                    .ok_or(EditError::InvalidEvidence)?;
                let inverse = super::preflight::file(artifact, result.index())?;
                completed.push((original, inverse.path.clone(), result.clone()));
            }
            for snapshot in &mut self.snapshots {
                if &snapshot.session != session || snapshot.service_id != service_id {
                    continue;
                }
                for (original, path, version) in &completed {
                    if &snapshot.edit_id == target {
                        snapshot.remaining.remove(original);
                    }
                    for index in &snapshot.remaining {
                        let before = super::preflight::file(&snapshot.artifact, *index)?;
                        if &before.path == path {
                            Arc::make_mut(&mut snapshot.receipt).rebase(&before.relative, version);
                        }
                    }
                }
            }
            self.snapshots.retain(|s| !s.remaining.is_empty());
            for (_, path, version) in &completed {
                let baseline = self
                    .changes
                    .iter()
                    .find(|record| {
                        &record.session == session
                            && record.service_id == service_id
                            && &record.full_path == path
                    })
                    .map(|record| record.baseline.without_diagnostics());
                let remaining_for_path = self.snapshots.iter().rev().find_map(|s| {
                    if &s.session != session || s.service_id != service_id {
                        return None;
                    }
                    for index in &s.remaining {
                        if let Ok(before) = super::preflight::file(&s.artifact, *index)
                            && &before.path == path
                            && let Some(r) = s.receipt.files().get(index.get())
                        {
                            return Some((
                                s.edit_id.clone(),
                                *index,
                                before.root.path().to_path_buf(),
                                before.path.clone(),
                                before.relative.clone(),
                                r.clone(),
                            ));
                        }
                    }
                    None
                });
                self.changes.retain(|record| {
                    !(&record.session == session
                        && record.service_id == service_id
                        && &record.full_path == path)
                });
                // Net-zero is determined by retained identity, never by the absence
                // of an undo body. Evicted bodies cannot erase verification debt.
                if baseline
                    .as_ref()
                    .is_some_and(|original| original.matches(version.final_hash()))
                {
                    continue;
                }
                if let Some((prev_edit, prev_index, prev_root, prev_full, prev_rel, prev_res)) =
                    remaining_for_path
                {
                    super::history::publish_change(
                        &mut self.changes,
                        super::history::ChangedFileRecord {
                            session: session.clone(),
                            service_id: service_id.clone(),
                            edit_id: prev_edit,
                            revision,
                            file: prev_index,
                            root: prev_root,
                            full_path: prev_full,
                            path: prev_rel,
                            outcome: prev_res.outcome(),
                            final_hash: version.final_hash().or_else(|| prev_res.final_hash()),
                            baseline: baseline
                                .unwrap_or(super::history::ChangeBaseline::Unavailable),
                            document: version
                                .final_document
                                .clone()
                                .or_else(|| prev_res.final_document.clone()),
                            disk: version.final_disk.clone(),
                            hunks: prev_res.hunks(),
                            saved: version.saved(),
                            hook_modified: prev_res.hook_modified(),
                            verification_pending: true,
                        },
                    )?;
                } else if let Some(baseline) = baseline {
                    let inverse = super::preflight::file(artifact, version.index())?;
                    super::history::publish_change(
                        &mut self.changes,
                        super::history::ChangedFileRecord {
                            session: session.clone(),
                            service_id: service_id.clone(),
                            edit_id: edit_id.clone(),
                            revision,
                            file: version.index(),
                            root: inverse.root.path().to_path_buf(),
                            full_path: path.clone(),
                            path: inverse.relative.clone(),
                            outcome: version.outcome(),
                            final_hash: version.final_hash(),
                            baseline,
                            document: version.final_document.clone(),
                            disk: version.final_disk.clone(),
                            hunks: version.hunks(),
                            saved: version.saved(),
                            hook_modified: version.hook_modified(),
                            verification_pending: true,
                        },
                    )?;
                }
            }
            return Ok(super::AppliedPublication::default());
        }
        for result in receipt.files().iter().filter(|r| {
            matches!(
                r.outcome(),
                super::receipt::FileOutcome::Applied | super::receipt::FileOutcome::Partial
            )
        }) {
            let file = super::preflight::file(artifact, result.index())?;
            let baseline = self
                .changes
                .iter()
                .find(|record| {
                    &record.session == session
                        && record.service_id == service_id
                        && record.full_path == file.path
                })
                .map_or_else(
                    || super::history::ChangeBaseline::Known {
                        original: file.evidence.existed().then_some(file.base_hash),
                        diagnostics: result.diagnostic_baseline().clone(),
                    },
                    |record| {
                        if record.verification_pending {
                            record.baseline.clone()
                        } else {
                            record
                                .baseline
                                .with_diagnostics(result.diagnostic_baseline().clone())
                        }
                    },
                );
            self.changes.retain(|record| {
                !(&record.session == session
                    && record.service_id == service_id
                    && record.full_path == file.path)
            });
            super::history::publish_change(
                &mut self.changes,
                super::history::ChangedFileRecord {
                    session: session.clone(),
                    service_id: service_id.clone(),
                    edit_id: edit_id.clone(),
                    revision,
                    file: result.index(),
                    root: file.root.path().to_path_buf(),
                    full_path: file.path.clone(),
                    path: file.relative.clone(),
                    outcome: result.outcome(),
                    final_hash: result.final_hash(),
                    baseline,
                    document: result.final_document.clone(),
                    disk: result.final_disk.clone(),
                    hunks: result.hunks(),
                    saved: result.saved(),
                    hook_modified: result.hook_modified(),
                    verification_pending: true,
                },
            )?;
        }
        if !receipt.has_applied() {
            return Ok(super::AppliedPublication {
                rollback_available: false,
                edit_revision: Some(revision),
            });
        }
        let remaining = receipt
            .files()
            .iter()
            .filter(|r| r.outcome() == super::receipt::FileOutcome::Applied)
            .map(|r| r.index())
            .collect();
        let snapshot = super::AppliedSnapshot {
            session: session.clone(),
            service_id,
            edit_id: edit_id.clone(),
            artifact: artifact.clone(),
            receipt: Arc::new(receipt.clone()),
            remaining,
        };
        let bytes = snapshot.retained_bytes()?;
        if bytes > limits::EDIT_HISTORY_BYTES {
            return Err(CoreError::Limit);
        }
        loop {
            let retained = self.snapshots.iter().try_fold(bytes, |n, snapshot| {
                n.checked_add(snapshot.retained_bytes()?)
                    .ok_or(CoreError::Limit)
            })?;
            if self.snapshots.len() < limits::EDIT_SNAPSHOTS
                && retained <= limits::EDIT_HISTORY_BYTES
            {
                break;
            }
            self.snapshots.pop_front().ok_or(CoreError::Limit)?;
        }
        self.snapshots.push_back(snapshot);
        Ok(super::AppliedPublication {
            rollback_available: true,
            edit_revision: Some(revision),
        })
    }
    pub(crate) fn prepare_rollback(
        &mut self,
        session: &SessionId,
        input: super::rollback::RollbackInput,
        now: Instant,
    ) -> Result<super::rollback::RollbackWork, CoreError> {
        self.sweep(now);
        if input.mode != Mode::Agent {
            return Err(CoreError::Rejected);
        }
        let selected = self
            .snapshots
            .iter()
            .rev()
            .find_map(|snapshot| {
                if &snapshot.session != session
                    || snapshot.service_id != input.service_id
                    || input
                        .target_edit_id
                        .as_ref()
                        .is_some_and(|id| id != &snapshot.edit_id)
                {
                    return None;
                }
                let files: Vec<_> = snapshot
                    .remaining
                    .iter()
                    .filter(|index| {
                        super::preflight::file(&snapshot.artifact, **index).is_ok_and(|file| {
                            input
                                .root
                                .as_ref()
                                .is_none_or(|root| root == file.root.path())
                                && input
                                    .target_file()
                                    .as_ref()
                                    .is_none_or(|path| path == &file.relative)
                        })
                    })
                    .copied()
                    .collect();
                if files.is_empty() {
                    None
                } else {
                    Some((snapshot.clone(), files))
                }
            })
            .ok_or(CoreError::Unavailable)?;
        let reserved = Reservation(limits::EDIT_BUFFER_BYTES);
        let total = self.entries.values().try_fold(reserved.0, |n, e| {
            n.checked_add(e.reserved.0).ok_or(CoreError::Limit)
        })?;
        if self.entries.len() >= limits::EDIT_PREPARATIONS || total > limits::EDIT_BUFFER_BYTES {
            return Err(CoreError::Limit);
        }
        self.admit_service(session, input.service_id.as_ref())?;
        let id = PreparationId::new();
        self.entries.insert(
            id.clone(),
            Entry {
                owner: Owner {
                    session: session.clone(),
                    origin: input.origin_id().clone(),
                    service_id: input.service_id.clone(),
                },
                reserved,
                expires: now
                    .checked_add(timeouts::WORKSPACE_READ)
                    .ok_or(CoreError::ArithmeticOverflow)?,
                phase: Phase::Preparing { revoked: false },
                provenance: Provenance::Rollback {
                    target: selected.0.edit_id.clone(),
                    files: selected.1.clone(),
                },
            },
        );
        Ok(super::rollback::RollbackWork {
            id,
            snapshot: selected.0,
            files: selected.1,
            input,
        })
    }
    pub(crate) fn can_publish(
        &self,
        session: &SessionId,
        id: &PreparationId,
        now: Instant,
    ) -> bool {
        self.entries.get(id).is_some_and(|entry| {
            &entry.owner.session == session
                && now < entry.expires
                && matches!(entry.phase, Phase::Preparing { revoked: false })
        })
    }
    pub(crate) fn finish(
        &mut self,
        session: &SessionId,
        id: &PreparationId,
        result: Result<PreparationResult, CoreError>,
        now: Instant,
    ) -> Result<Value, Fault> {
        self.finish_inner(session, id, result, now)
            .map_err(super::fault)
    }
    fn finish_inner(
        &mut self,
        session: &SessionId,
        id: &PreparationId,
        result: Result<PreparationResult, CoreError>,
        now: Instant,
    ) -> Result<Value, CoreError> {
        let entry = self.entries.get(id).ok_or(CoreError::StaleOwner)?;
        if &entry.owner.session != session || !matches!(entry.phase, Phase::Preparing { .. }) {
            return Err(CoreError::StaleOwner);
        }
        let mut entry = self.entries.remove(id).ok_or(CoreError::StaleOwner)?;
        // Ownership and deadline terminal states outrank an internal revoke marker.
        if matches!(result, Err(CoreError::StaleOwner | CoreError::Deadline)) {
            return result.map(|_| Value::Null);
        }
        if now >= entry.expires {
            return Err(CoreError::Deadline);
        }
        if matches!(
            entry.phase,
            Phase::Preparing { revoked: true } | Phase::Claimed { revoked: true, .. }
        ) {
            return Err(CoreError::Cancelled);
        }
        let descriptor = match result? {
            PreparationResult::Complete(prepared) => {
                entry.reserved = Reservation(prepared.retained_bytes()?.get());
                let descriptor = prepared.descriptor(id);
                entry.phase = Phase::Ready(Box::new(prepared));
                entry.expires = now
                    .checked_add(timeouts::APPROVAL)
                    .ok_or(CoreError::ArithmeticOverflow)?;
                descriptor
            }
            PreparationResult::Inspected(patch) => {
                let descriptor = patch.descriptor(id);
                entry.phase = Phase::Collecting(patch);
                descriptor
            }
        };
        let descriptor = if let Provenance::Rollback { target, .. } = &entry.provenance {
            let mut descriptor = descriptor;
            if let Some(object) = descriptor.as_object_mut() {
                object.insert("rollback_target_edit_id".into(), json!(target));
            }
            json!({"preparation_id":id,"target_edit_id":target,"descriptor":descriptor})
        } else {
            descriptor
        };
        self.entries.insert(id.clone(), entry);
        Ok(descriptor)
    }
}

#[cfg(test)]
mod tests;
