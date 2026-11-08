//! Pure schema migration and candidate generation for imported sessions.
//!
//! Enforces:
//! - Conversion of legacy formats (missing schema_version or v1) to canonical v2 candidates.
//! - Explicit collision policy (Reject, DeriveWithPrefix, Override).
//! - Zero mutation of source file or source data during candidate conversion.
//! - Strict schema and content boundary validation before candidate emission.

use crate::{
    constants::limits,
    persistence::domain::{PersistenceError, SessionRecord, StorageSessionId},
};

/// Raw, unparsed session JSON input payload.
#[derive(Clone, Eq, PartialEq)]
pub struct RawSessionPayload(String);

impl RawSessionPayload {
    /// Borrow raw string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for RawSessionPayload {
    type Error = PersistenceError;

    fn try_from(val: String) -> Result<Self, Self::Error> {
        if val.len() > limits::SESSION_MAX_FILE_BYTES {
            return Err(PersistenceError::SizeLimitExceeded);
        }
        Ok(Self(val))
    }
}

impl TryFrom<&str> for RawSessionPayload {
    type Error = PersistenceError;

    fn try_from(val: &str) -> Result<Self, Self::Error> {
        Self::try_from(val.to_owned())
    }
}

/// Policy for handling session identifier collisions when importing sessions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CollisionPolicy {
    /// Reject collisions strictly.
    Reject,
    /// Generate a replacement identifier by joining a prefix to the original identifier.
    DeriveWithPrefix(StorageSessionId),
    /// Use an explicit replacement identifier.
    Override(StorageSessionId),
}

/// Detected schema format of the imported session source.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionSourceFormat {
    /// Legacy schema (missing schema_version or schema_version == 1).
    LegacyV1,
    /// Canonical v2 schema.
    CanonicalV2,
}

/// A validated candidate session ready for persistence or restore.
#[derive(Clone, Debug)]
pub struct SessionCandidate {
    record: SessionRecord,
    source_format: SessionSourceFormat,
    id: StorageSessionId,
}

impl SessionCandidate {
    /// Return the validated record.
    pub fn record(&self) -> &SessionRecord {
        &self.record
    }

    /// Detected format of source data before migration.
    pub fn source_format(&self) -> SessionSourceFormat {
        self.source_format
    }

    /// Resolved candidate session identity.
    pub fn id(&self) -> &StorageSessionId {
        &self.id
    }
}

/// Parse, migrate if necessary, and strictly validate a session candidate.
///
/// This function is entirely pure and produces no filesystem side effects.
pub fn migrate_candidate(
    payload: &RawSessionPayload,
    policy: &CollisionPolicy,
) -> Result<SessionCandidate, PersistenceError> {
    let parsed: serde_json::Value = serde_json::from_str(payload.as_str())
        .map_err(|_| PersistenceError::Validation("invalid JSON in candidate"))?;
    let source_format = detect_format(&parsed)?;
    let candidate_val = build_candidate_json(parsed, source_format)?;
    let record = SessionRecord::try_from(candidate_val.to_string().as_str())?;
    let target_id = resolve_candidate_id(record.id(), policy)?;
    let final_record = adjust_record_id(record, &target_id);
    Ok(SessionCandidate {
        record: final_record,
        source_format,
        id: target_id,
    })
}

fn detect_format(val: &serde_json::Value) -> Result<SessionSourceFormat, PersistenceError> {
    match val
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
    {
        None | Some(1) => Ok(SessionSourceFormat::LegacyV1),
        Some(2) => Ok(SessionSourceFormat::CanonicalV2),
        Some(other) => Err(PersistenceError::UnsupportedVersion(other as u32)),
    }
}

fn build_candidate_json(
    mut val: serde_json::Value,
    format: SessionSourceFormat,
) -> Result<serde_json::Value, PersistenceError> {
    if format == SessionSourceFormat::LegacyV1 {
        let obj = val
            .as_object_mut()
            .ok_or(PersistenceError::Validation("session root must be object"))?;
        obj.insert("schema_version".to_owned(), serde_json::json!(2));
        if !obj.contains_key("effort") {
            obj.insert("effort".to_owned(), serde_json::json!({"kind": "inherit"}));
        }
    }
    Ok(val)
}

fn resolve_candidate_id(
    orig: &StorageSessionId,
    policy: &CollisionPolicy,
) -> Result<StorageSessionId, PersistenceError> {
    match policy {
        CollisionPolicy::Reject => Ok(orig.clone()),
        CollisionPolicy::DeriveWithPrefix(prefix) => {
            let derived = format!("{}-{}", prefix.as_str(), orig.as_str());
            StorageSessionId::try_from(derived)
        }
        CollisionPolicy::Override(explicit) => Ok(explicit.clone()),
    }
}

fn adjust_record_id(record: SessionRecord, target_id: &StorageSessionId) -> SessionRecord {
    if record.id() == target_id {
        record
    } else {
        record.with_id(target_id.clone())
    }
}
