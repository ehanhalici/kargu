//! Exact metadata upload identities, offsets, DTOs and protocol fault projection.

use crate::{
    constants::{limits, protocol},
    ipc::protocol::Fault,
    models::{
        metadata::EffortSpecs,
        store::{MetadataRevision, StoreError},
    },
    providers::ApiProviderId,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "String", into = "String")]
pub(super) struct UploadId(uuid::Uuid);
impl UploadId {
    pub(super) fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
impl TryFrom<String> for UploadId {
    type Error = ServiceError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        uuid::Uuid::parse_str(
            value
                .strip_prefix("metadata_")
                .ok_or(ServiceError::Invalid)?,
        )
        .map(Self)
        .map_err(|_| ServiceError::Invalid)
    }
}
impl From<UploadId> for String {
    fn from(value: UploadId) -> Self {
        format!("metadata_{}", value.0)
    }
}

macro_rules! offset {
    ($name:ident, $max:expr) => {
        #[derive(Clone, Copy, Default, Deserialize, Eq, PartialEq, Serialize)]
        #[serde(try_from = "usize")]
        pub(super) struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = ServiceError;
            fn try_from(value: usize) -> Result<Self, Self::Error> {
                if value > $max {
                    return Err(ServiceError::Limit);
                }
                Ok(Self(value))
            }
        }
        impl $name {
            pub(super) fn get(self) -> usize {
                self.0
            }
        }
    };
}
offset!(UploadOffset, limits::MODEL_CATALOG_BYTES);
offset!(SnapshotOffset, limits::MODEL_SNAPSHOT_BYTES);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Begin {
    pub provider: ApiProviderId,
    pub revision: MetadataRevision,
    #[serde(default)]
    pub effort_specs: EffortSpecs,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Append {
    pub upload_id: UploadId,
    pub offset: UploadOffset,
    pub chunk: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Upload {
    pub upload_id: UploadId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Read {
    pub revision: MetadataRevision,
    pub offset: SnapshotOffset,
}

#[derive(Debug, thiserror::Error)]
pub(super) enum ServiceError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("Invalid metadata transfer")]
    Invalid,
    #[error("Metadata transfer limit exceeded")]
    Limit,
    #[error("Metadata upload already in progress")]
    Busy,
    #[error("Obsolete metadata transfer")]
    Stale,
    #[error("Metadata upload deadline elapsed")]
    Deadline,
}
impl From<ServiceError> for Fault {
    fn from(error: ServiceError) -> Self {
        let (code, message, status) = match error {
            ServiceError::Stale | ServiceError::Store(StoreError::Stale) => (
                protocol::error_codes::STALE_OWNER,
                "Obsolete metadata transfer",
                "stale_metadata",
            ),
            ServiceError::Deadline => (
                protocol::error_codes::TIMEOUT,
                "Metadata upload deadline elapsed",
                "timeout",
            ),
            ServiceError::Limit | ServiceError::Store(StoreError::Limit | StoreError::Overflow) => {
                (
                    protocol::error_codes::RESOURCE_LIMIT,
                    "Metadata transfer limit exceeded",
                    "resource_limit",
                )
            }
            ServiceError::Busy => (
                protocol::error_codes::INVALID_STATE,
                "Metadata upload already in progress",
                "metadata_busy",
            ),
            ServiceError::Store(StoreError::Ambiguous) => (
                protocol::error_codes::INVALID_PARAMS,
                "Ambiguous model alias; use the full identifier",
                "ambiguous_model",
            ),
            ServiceError::Invalid | ServiceError::Store(_) => (
                protocol::error_codes::INVALID_PARAMS,
                "Invalid model metadata update",
                "invalid_metadata",
            ),
        };
        Self {
            code,
            message,
            status,
        }
    }
}
