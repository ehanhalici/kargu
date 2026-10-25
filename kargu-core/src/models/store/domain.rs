//! Parse-once update commands, revision identity and closed publication errors.

use crate::{
    api::ModelId,
    constants::limits,
    models::{
        catalog::ModelCatalog,
        metadata::{MetadataError, RawMetadata},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

/// An application metadata revision, not a request generation or config revision.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct MetadataRevision(u64);
impl MetadataRevision {
    pub(super) fn next(self) -> Result<Self, StoreError> {
        self.0.checked_add(1).map(Self).ok_or(StoreError::Overflow)
    }
}

/// Payload-free update failures; raw provider metadata is never diagnostic text.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum StoreError {
    /// Invalid command/record/property syntax or identity.
    #[error("Invalid model metadata update")]
    Invalid,
    /// Ambiguous provider-local short alias.
    #[error("Ambiguous model alias; use the full identifier")]
    Ambiguous,
    /// A newer update or another owner invalidated this prepared publication.
    #[error("Obsolete model metadata publication")]
    Stale,
    /// Resource capacity, never truncated successful publication.
    #[error("Model metadata storage limit exceeded")]
    Limit,
    /// Revision exhaustion.
    #[error("Model metadata revision exhausted")]
    Overflow,
    /// Typed structural metadata boundary failure.
    #[error(transparent)]
    Metadata(#[from] MetadataError),
}

pub(super) struct PropertyName(String);
impl TryFrom<String> for PropertyName {
    type Error = StoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let canonical = match value.as_str() {
            "context-window" => "context_length",
            "max-output" => "max_output",
            "supports-tools" => "supports_tools",
            "supports-reasoning" => "supports_reasoning",
            _ => &value,
        };
        if canonical.is_empty()
            || canonical.len() > 256
            || canonical.chars().any(char::is_control)
            || matches!(canonical, "provider" | "id")
        {
            return Err(StoreError::Invalid);
        }
        Ok(Self(canonical.to_owned()))
    }
}
impl PropertyName {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Kind {
    Put,
    Override,
    ReplaceCatalog,
    RefuseTools,
    ClearToolRefusals,
}
#[derive(Deserialize)]
struct Tag {
    operation: Kind,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Put {
    #[serde(rename = "operation")]
    _operation: Kind,
    model: String,
    metadata: Box<RawValue>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Override {
    #[serde(rename = "operation")]
    _operation: Kind,
    model: String,
    property: String,
    value: Box<RawValue>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Catalog {
    #[serde(rename = "operation")]
    _operation: Kind,
    catalog: Box<RawValue>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Refusal {
    #[serde(rename = "operation")]
    _operation: Kind,
    model: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Clear {
    #[serde(rename = "operation")]
    _operation: Kind,
}
fn decode<'de, T: Deserialize<'de>>(source: &'de str) -> Result<T, StoreError> {
    serde_json::from_str(source).map_err(|_| StoreError::Invalid)
}
pub(super) enum Operation {
    Put {
        model: ModelId,
        metadata: RawMetadata,
    },
    Override {
        model: ModelId,
        property: PropertyName,
        value: Box<RawValue>,
    },
    ReplaceCatalog(ModelCatalog),
    RefuseTools(ModelId),
    ClearToolRefusals,
}
/// A fully parsed update; callers cannot construct a half-validated command.
pub struct ModelUpdate(pub(super) Operation);
fn model(value: String) -> Result<ModelId, StoreError> {
    ModelId::try_from(value.trim().to_owned()).map_err(|_| StoreError::Invalid)
}
impl TryFrom<&str> for ModelUpdate {
    type Error = StoreError;
    fn try_from(source: &str) -> Result<Self, Self::Error> {
        if source.len() > limits::MODEL_CATALOG_BYTES {
            return Err(StoreError::Limit);
        }
        // Internally-tagged serde enums buffer through Content, which cannot
        // retain RawValue source spans. Read the tag, then decode a direct DTO.
        let tag: Tag = decode(source)?;
        let operation = match tag.operation {
            Kind::Put => {
                let Put {
                    model: id,
                    metadata,
                    ..
                } = decode(source)?;
                Operation::Put {
                    model: model(id)?,
                    metadata: RawMetadata::try_from(metadata.get())?,
                }
            }
            Kind::Override => {
                let Override {
                    model: id,
                    property,
                    value,
                    ..
                } = decode(source)?;
                Operation::Override {
                    model: model(id)?,
                    property: PropertyName::try_from(property)?,
                    value,
                }
            }
            Kind::ReplaceCatalog => {
                let Catalog { catalog, .. } = decode(source)?;
                Operation::ReplaceCatalog(ModelCatalog::try_from(catalog.get()).map_err(
                    |error| match error {
                        crate::models::catalog::CatalogError::Limit => StoreError::Limit,
                        _ => StoreError::Invalid,
                    },
                )?)
            }
            Kind::RefuseTools => {
                let Refusal { model: id, .. } = decode(source)?;
                Operation::RefuseTools(model(id)?)
            }
            Kind::ClearToolRefusals => {
                let _: Clear = decode(source)?;
                Operation::ClearToolRefusals
            }
        };
        Ok(Self(operation))
    }
}
