//! Pure domain implementation plan state, hashing, and lifecycle tracking.
//!
//! A plan record is owned by exactly one session and tracks:
//! - An immutable unique artifact ID (`PlanId`).
//! - Origin session identity (`SessionId`).
//! - Monotonic content revision (`PlanRevision`).
//! - Cryptographic content commitment (`PlanHash`).
//! - Native lifecycle state (`PlanState`).
//! - Decoded, bounded plan text.
//!
//! Approvals are single-use: claiming transitions `Pending` -> `Dispatching`.
//! Once claimed, rejected, superseded, or terminal, subsequent claims are refused.
//! Content changes bump the revision and hash, invalidating stale claims.

use crate::{
    constants::limits,
    domain::{PlanId, PlanRevision, SessionId},
    error::CoreError,
};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Cryptographic SHA-256 hash of plan content.
#[derive(Clone, Copy, Eq, PartialEq)]
pub struct PlanHash([u8; 32]);

impl PlanHash {
    /// Compute SHA-256 digest over normalized plan text.
    pub fn compute(text: &str) -> Self {
        Self(Sha256::digest(text.as_bytes()).into())
    }

    /// Access raw digest bytes.
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// Render 64-character lowercase hex string.
    pub fn to_hex(&self) -> String {
        let mut s = String::with_capacity(64);
        for b in &self.0 {
            use std::fmt::Write;
            let _ = write!(s, "{:02x}", b);
        }
        s
    }

    /// Parse from a 64-character hex string.
    pub fn from_hex(hex: &str) -> Result<Self, CoreError> {
        if hex.len() != 64 {
            return Err(CoreError::InvalidValue { field: "plan_hash" });
        }
        let mut bytes = [0u8; 32];
        let raw = hex.as_bytes();
        for (i, slot) in bytes.iter_mut().enumerate() {
            let offset = i.checked_mul(2).ok_or(CoreError::ArithmeticOverflow)?;
            let b0 = raw
                .get(offset)
                .copied()
                .ok_or(CoreError::InvalidValue { field: "plan_hash" })?;
            let b1 = raw
                .get(offset.saturating_add(1))
                .copied()
                .ok_or(CoreError::InvalidValue { field: "plan_hash" })?;
            let pair = [b0, b1];
            let hex_slice = std::str::from_utf8(&pair)
                .map_err(|_| CoreError::InvalidValue { field: "plan_hash" })?;
            *slot = u8::from_str_radix(hex_slice, 16)
                .map_err(|_| CoreError::InvalidValue { field: "plan_hash" })?;
        }
        Ok(Self(bytes))
    }
}

impl std::fmt::Debug for PlanHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PlanHash({})", self.to_hex())
    }
}

impl std::fmt::Display for PlanHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_hex())
    }
}

impl Serialize for PlanHash {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for PlanHash {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Self::from_hex(&s).map_err(serde::de::Error::custom)
    }
}

/// Native lifecycle state of an implementation plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlanState {
    /// Awaiting user review and decision.
    Pending,
    /// Claimed for execution; single-use accept taken.
    Dispatching,
    /// Explicitly rejected by user.
    Rejected,
    /// Replaced by a newer plan or cancelled.
    Superseded,
    /// Execution settled; terminal state.
    Terminal,
}

/// Bounded implementation plan text.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PlanText(String);

impl PlanText {
    /// Validate plan text length against `limits::PLAN_TEXT_BYTES`.
    pub fn try_new(text: String) -> Result<Self, CoreError> {
        if text.len() > limits::PLAN_TEXT_BYTES {
            return Err(CoreError::InvalidValue { field: "plan_text" });
        }
        Ok(Self(text))
    }

    /// Borrow plan text.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for PlanText {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        Self::try_new(value)
    }
}

impl TryFrom<&str> for PlanText {
    type Error = CoreError;
    fn try_from(value: &str) -> Result<Self, CoreError> {
        Self::try_new(value.to_owned())
    }
}

/// Whether a claimed plan dispatch succeeded.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct PlanDispatchSuccess(bool);

impl PlanDispatchSuccess {
    /// Wrap raw dispatch outcome flag.
    pub const fn new(success: bool) -> Self {
        Self(success)
    }

    /// Extract underlying flag.
    pub const fn get(self) -> bool {
        self.0
    }
}

impl From<bool> for PlanDispatchSuccess {
    fn from(value: bool) -> Self {
        Self(value)
    }
}

/// Owned plan artifact within one session.
#[derive(Clone, Debug, Serialize)]
pub struct PlanRecord {
    id: PlanId,
    origin: SessionId,
    revision: PlanRevision,
    content_hash: PlanHash,
    state: PlanState,
    text: PlanText,
}

impl PlanRecord {
    /// Create a fresh pending plan artifact for an originating session.
    pub fn new(id: PlanId, origin: SessionId, text: PlanText) -> Self {
        let content_hash = PlanHash::compute(text.as_str());
        Self {
            id,
            origin,
            revision: PlanRevision::ONE,
            content_hash,
            state: PlanState::Pending,
            text,
        }
    }

    /// Access unique artifact identifier.
    pub const fn id(&self) -> &PlanId {
        &self.id
    }

    /// Access originating conversation identity.
    pub const fn origin(&self) -> &SessionId {
        &self.origin
    }

    /// Monotonic content revision.
    pub const fn revision(&self) -> PlanRevision {
        self.revision
    }

    /// Cryptographic content commitment.
    pub const fn content_hash(&self) -> PlanHash {
        self.content_hash
    }

    /// Current lifecycle state.
    pub const fn state(&self) -> PlanState {
        self.state
    }

    /// Borrow plan text.
    pub const fn text(&self) -> &PlanText {
        &self.text
    }

    /// Revise plan content, bumping monotonic revision on content changes.
    pub fn revise(
        &mut self,
        expected_revision: PlanRevision,
        new_text: PlanText,
    ) -> Result<(), CoreError> {
        if self.state != PlanState::Pending {
            return Err(CoreError::AlreadyCompleted);
        }
        if self.revision != expected_revision {
            return Err(CoreError::StaleOwner);
        }
        let new_hash = PlanHash::compute(new_text.as_str());
        if new_hash != self.content_hash {
            self.revision = self.revision.next()?;
            self.content_hash = new_hash;
            self.text = new_text;
        }
        Ok(())
    }

    /// Claim the plan for execution (single-use accept).
    pub fn claim(
        &mut self,
        expected_revision: PlanRevision,
        expected_hash: PlanHash,
    ) -> Result<(), CoreError> {
        if self.state != PlanState::Pending {
            return Err(CoreError::AlreadyCompleted);
        }
        if self.revision != expected_revision || self.content_hash != expected_hash {
            return Err(CoreError::StaleOwner);
        }
        self.state = PlanState::Dispatching;
        Ok(())
    }

    /// Settle claimed dispatch: terminal on success, back to pending on retry.
    pub fn complete_dispatch(&mut self, success: PlanDispatchSuccess) -> Result<(), CoreError> {
        if self.state != PlanState::Dispatching {
            return Err(CoreError::StaleOwner);
        }
        self.state = if success.get() {
            PlanState::Terminal
        } else {
            PlanState::Pending
        };
        Ok(())
    }

    /// Reject the pending plan.
    pub fn reject(&mut self, expected_revision: PlanRevision) -> Result<(), CoreError> {
        if self.state != PlanState::Pending {
            return Err(CoreError::AlreadyCompleted);
        }
        if self.revision != expected_revision {
            return Err(CoreError::StaleOwner);
        }
        self.state = PlanState::Rejected;
        Ok(())
    }

    /// Supersede or cancel this plan.
    pub fn supersede(&mut self) {
        if matches!(self.state, PlanState::Pending | PlanState::Dispatching) {
            self.state = PlanState::Superseded;
        }
    }
}

/// Intent to claim a plan for execution.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlanClaimIntent {
    expected_revision: PlanRevision,
    expected_hash: PlanHash,
}

impl PlanClaimIntent {
    /// Create a validated claim intent.
    pub const fn new(expected_revision: PlanRevision, expected_hash: PlanHash) -> Self {
        Self {
            expected_revision,
            expected_hash,
        }
    }

    /// Expected revision.
    pub const fn expected_revision(self) -> PlanRevision {
        self.expected_revision
    }

    /// Expected content hash.
    pub const fn expected_hash(self) -> PlanHash {
        self.expected_hash
    }
}

/// Intent to revise plan content.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanReviseIntent {
    expected_revision: PlanRevision,
    text: PlanText,
}

impl PlanReviseIntent {
    /// Create a validated revision intent.
    pub const fn new(expected_revision: PlanRevision, text: PlanText) -> Self {
        Self {
            expected_revision,
            text,
        }
    }

    /// Expected revision.
    pub const fn expected_revision(&self) -> PlanRevision {
        self.expected_revision
    }

    /// Decoded new text.
    pub const fn text(&self) -> &PlanText {
        &self.text
    }

    /// Consume into new text.
    pub fn into_text(self) -> PlanText {
        self.text
    }
}

/// Per-session implementation plan store.
#[derive(Clone, Debug, Default)]
pub struct SessionPlanStore {
    active: Option<PlanId>,
    records: HashMap<PlanId, PlanRecord>,
}

impl SessionPlanStore {
    /// Read currently active plan record, if any.
    pub fn active_record(&self) -> Option<&PlanRecord> {
        let id = self.active.as_ref()?;
        self.records.get(id)
    }

    /// Look up plan record by identifier.
    pub fn get_record(&self, id: &PlanId) -> Option<&PlanRecord> {
        self.records.get(id)
    }

    /// Create or replace the active plan for this session.
    pub fn create_or_replace(
        &mut self,
        origin: SessionId,
        text: PlanText,
    ) -> Result<&PlanRecord, CoreError> {
        if let Some(old_id) = self.active.take() {
            let _ = self.records.get_mut(&old_id).map(|r| r.supersede());
        }
        if self.records.len() >= limits::SESSION_PLANS {
            let evict_key = self.records.keys().next().cloned();
            if let Some(k) = evict_key {
                self.records.remove(&k);
            }
        }
        let id = PlanId::new();
        let record = PlanRecord::new(id.clone(), origin, text);
        self.records.insert(id.clone(), record);
        self.active = Some(id.clone());
        self.records.get(&id).ok_or(CoreError::Unavailable)
    }

    /// Revise plan content and bump revision.
    pub fn revise(
        &mut self,
        id: &PlanId,
        intent: PlanReviseIntent,
    ) -> Result<&PlanRecord, CoreError> {
        let record = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        record.revise(intent.expected_revision(), intent.into_text())?;
        self.records.get(id).ok_or(CoreError::Unavailable)
    }

    /// Claim plan for execution (single-use accept).
    pub fn claim(
        &mut self,
        id: &PlanId,
        intent: PlanClaimIntent,
    ) -> Result<&PlanRecord, CoreError> {
        let record = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        record.claim(intent.expected_revision(), intent.expected_hash())?;
        self.records.get(id).ok_or(CoreError::Unavailable)
    }

    /// Settle claimed dispatch.
    pub fn complete_dispatch(
        &mut self,
        id: &PlanId,
        success: PlanDispatchSuccess,
    ) -> Result<PlanState, CoreError> {
        let record = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        record.complete_dispatch(success)?;
        Ok(record.state())
    }

    /// Reject pending plan.
    pub fn reject(
        &mut self,
        id: &PlanId,
        expected_revision: PlanRevision,
    ) -> Result<PlanState, CoreError> {
        let record = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        record.reject(expected_revision)?;
        Ok(record.state())
    }

    /// Cancel/supersede plan.
    pub fn cancel(&mut self, id: &PlanId) -> Result<(), CoreError> {
        let record = self.records.get_mut(id).ok_or(CoreError::StaleOwner)?;
        record.supersede();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn plan_creation_has_revision_one_and_pending_state() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record =
            store.create_or_replace(origin.clone(), PlanText::try_from("Step 1: check files")?)?;
        assert_eq!(record.revision(), PlanRevision::ONE);
        assert_eq!(record.state(), PlanState::Pending);
        assert_eq!(record.origin(), &origin);
        assert_eq!(record.text().as_str(), "Step 1: check files");
        assert_eq!(
            record.content_hash(),
            PlanHash::compute("Step 1: check files")
        );
        Ok(())
    }

    #[test]
    fn plan_revision_bumps_revision_and_updates_hash_on_change() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Draft 1")?)?;
        let id = record.id().clone();
        let hash1 = record.content_hash();

        let intent = PlanReviseIntent::new(PlanRevision::ONE, PlanText::try_from("Draft 2")?);
        let updated = store.revise(&id, intent)?;
        assert_eq!(updated.revision(), PlanRevision::from_u64(2));
        assert_eq!(updated.text().as_str(), "Draft 2");
        assert_ne!(updated.content_hash(), hash1);
        assert_eq!(updated.state(), PlanState::Pending);
        Ok(())
    }

    #[test]
    fn plan_revision_with_same_content_keeps_same_revision() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Same")?)?;
        let id = record.id().clone();

        let intent = PlanReviseIntent::new(PlanRevision::ONE, PlanText::try_from("Same")?);
        let updated = store.revise(&id, intent)?;
        assert_eq!(updated.revision(), PlanRevision::ONE);
        assert_eq!(updated.text().as_str(), "Same");
        Ok(())
    }

    #[test]
    fn plan_revision_rejects_stale_expected_revision() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Initial")?)?;
        let id = record.id().clone();

        let intent = PlanReviseIntent::new(PlanRevision::from_u64(999), PlanText::try_from("New")?);
        assert!(matches!(
            store.revise(&id, intent),
            Err(CoreError::StaleOwner)
        ));
        Ok(())
    }

    #[test]
    fn single_use_claim_moves_pending_to_dispatching() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("My Plan")?)?;
        let id = record.id().clone();
        let rev = record.revision();
        let hash = record.content_hash();

        let intent = PlanClaimIntent::new(rev, hash);
        let claimed = store.claim(&id, intent)?;
        assert_eq!(claimed.state(), PlanState::Dispatching);

        // Second claim attempt must fail because state is already dispatching
        assert!(matches!(
            store.claim(&id, intent),
            Err(CoreError::AlreadyCompleted)
        ));
        Ok(())
    }

    #[test]
    fn claim_rejects_stale_revision_or_mismatched_hash() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Initial")?)?;
        let id = record.id().clone();

        // Stale revision
        let intent_stale = PlanClaimIntent::new(PlanRevision::from_u64(999), record.content_hash());
        assert!(matches!(
            store.claim(&id, intent_stale),
            Err(CoreError::StaleOwner)
        ));

        // Mismatched hash
        let intent_bad_hash =
            PlanClaimIntent::new(PlanRevision::ONE, PlanHash::compute("Different text"));
        assert!(matches!(
            store.claim(&id, intent_bad_hash),
            Err(CoreError::StaleOwner)
        ));
        Ok(())
    }

    #[test]
    fn completing_dispatch_settles_to_terminal_or_pending() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Plan text")?)?;
        let id = record.id().clone();
        let intent = PlanClaimIntent::new(record.revision(), record.content_hash());
        store.claim(&id, intent)?;

        // Startup failure returns to pending to allow retry
        let state = store.complete_dispatch(&id, PlanDispatchSuccess::new(false))?;
        assert_eq!(state, PlanState::Pending);

        // Claim again
        store.claim(&id, intent)?;
        // Success moves to terminal
        let state = store.complete_dispatch(&id, PlanDispatchSuccess::new(true))?;
        assert_eq!(state, PlanState::Terminal);

        // Terminal plan cannot be claimed again
        assert!(matches!(
            store.claim(&id, intent),
            Err(CoreError::AlreadyCompleted)
        ));
        Ok(())
    }

    #[test]
    fn rejected_plan_cannot_be_claimed_or_revised() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let record = store.create_or_replace(origin, PlanText::try_from("Plan")?)?;
        let id = record.id().clone();
        let rev = record.revision();
        let hash = record.content_hash();

        let state = store.reject(&id, rev)?;
        assert_eq!(state, PlanState::Rejected);

        assert!(matches!(
            store.claim(&id, PlanClaimIntent::new(rev, hash)),
            Err(CoreError::AlreadyCompleted)
        ));

        assert!(matches!(
            store.revise(&id, PlanReviseIntent::new(rev, PlanText::try_from("New")?)),
            Err(CoreError::AlreadyCompleted)
        ));
        Ok(())
    }

    #[test]
    fn creating_new_plan_supersedes_previous_active_plan() -> TestResult {
        let origin = SessionId::new();
        let mut store = SessionPlanStore::default();
        let plan_a = store.create_or_replace(origin.clone(), PlanText::try_from("Plan A")?)?;
        let id_a = plan_a.id().clone();
        assert_eq!(plan_a.state(), PlanState::Pending);

        let (id_b, rev_b, hash_b) = {
            let plan_b = store.create_or_replace(origin, PlanText::try_from("Plan B")?)?;
            assert_eq!(plan_b.state(), PlanState::Pending);
            (
                plan_b.id().clone(),
                plan_b.revision(),
                plan_b.content_hash(),
            )
        };
        assert_ne!(id_a, id_b);

        // Plan A should now be superseded
        let (old_a_rev, old_a_hash) = {
            let old_a = store.get_record(&id_a).ok_or(CoreError::Unavailable)?;
            assert_eq!(old_a.state(), PlanState::Superseded);
            (old_a.revision(), old_a.content_hash())
        };

        // Superseded plan A cannot be claimed
        assert!(matches!(
            store.claim(&id_a, PlanClaimIntent::new(old_a_rev, old_a_hash)),
            Err(CoreError::AlreadyCompleted)
        ));

        // Plan B can still be claimed
        let claim_b = store.claim(&id_b, PlanClaimIntent::new(rev_b, hash_b))?;
        assert_eq!(claim_b.state(), PlanState::Dispatching);
        Ok(())
    }
}
