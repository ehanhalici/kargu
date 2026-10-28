//! One application-actor writer owns upload/adoption/expiry. Workers own only input.
use super::{
    Artifact, ClaimWork, PartBuffer, PreparationResult, Work,
    inspection::{Inspection, PatchWork, PrepareWork},
    types::{self, Begin, Intent, OriginId, Part, PreparationId},
};
use crate::{
    application::Mode,
    constants::{limits, protocol::methods, timeouts},
    domain::{ByteLimit, SessionId},
    edit::EditError,
    error::CoreError,
    ipc::protocol::Fault,
};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    sync::Arc,
    time::Instant,
};

#[derive(Clone, Copy)]
struct Reservation(usize);
struct Owner {
    session: SessionId,
    origin: OriginId,
}
struct Entry {
    owner: Owner,
    reserved: Reservation,
    expires: Instant,
    phase: Phase,
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
/// Actor-only store. The separate states never contain optional worker handles.
#[derive(Default)]
pub(crate) struct EditPreparations {
    entries: HashMap<PreparationId, Entry>,
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
    pub(crate) fn revoke(&mut self) {
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
                let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
                match (&entry.phase, method) {
                    (Phase::Collecting(patch), methods::EDIT_TARGETS) => {
                        patch.targets(input.offset, frame)
                    }
                    (Phase::Ready(artifact), methods::EDIT_FILES) => {
                        artifact.files(&input.preparation_id, input.offset, frame)
                    }
                    (Phase::Claimed { artifact, .. }, methods::EDIT_FILES) => {
                        artifact.files(&input.preparation_id, input.offset, frame)
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
                    if !entry.owner.matches(session, &input.origin_id) {
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
            Intent::Write { new_bytes, .. } => {
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
        let part_info: Vec<_> = parts
            .iter()
            .map(|(name, value)| json!({"part":name,"bytes":value.expected}))
            .collect();
        self.entries.insert(
            id.clone(),
            Entry {
                owner: Owner {
                    session: session.clone(),
                    origin: input.origin_id.clone(),
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
            })),
            Phase::Collecting(patch) => Ok(PrepareWork::Patch(PatchWork {
                id: input.preparation_id,
                inspection: *patch,
                deadline: entry.expires,
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
        let entry = self.owned(session, &input.origin_id, &input.preparation_id)?;
        if !matches!(entry.phase, Phase::Ready(_)) {
            return Err(CoreError::AlreadyCompleted);
        }
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
        })
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
        self.entries.insert(id.clone(), entry);
        Ok(descriptor)
    }
}
