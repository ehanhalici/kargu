//! Publication identity includes config sources, never another session's UI choice.

use super::domain::{ConfigurationDocument, PolicyContext};
use crate::{
    configuration::{domain::ConfigText, read::ConfigurationPath},
    error::CoreError,
};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

#[derive(Eq, PartialEq)]
pub(super) struct SourceFingerprint([u8; 32]);

fn text(hash: &mut Sha256, value: &str) -> Result<(), CoreError> {
    let length = u64::try_from(value.len()).map_err(|_| CoreError::ArithmeticOverflow)?;
    hash.update(length.to_le_bytes());
    hash.update(value.as_bytes());
    Ok(())
}
fn optional(hash: &mut Sha256, value: Option<&ConfigText>) -> Result<(), CoreError> {
    hash.update([u8::from(value.is_some())]);
    if let Some(value) = value {
        text(hash, value.as_str())?;
    }
    Ok(())
}
fn count(hash: &mut Sha256, value: usize) -> Result<(), CoreError> {
    hash.update(
        u64::try_from(value)
            .map_err(|_| CoreError::ArithmeticOverflow)?
            .to_le_bytes(),
    );
    Ok(())
}
impl SourceFingerprint {
    pub(super) fn capture(
        document: &ConfigurationDocument,
        context: &PolicyContext,
        path: &ConfigurationPath,
        digest: Option<&str>,
    ) -> Result<Self, CoreError> {
        let mut hash = Sha256::new();
        text(
            &mut hash,
            path.as_path().to_str().ok_or(CoreError::InvalidValue {
                field: "configuration_path",
            })?,
        )?;
        hash.update([u8::from(digest.is_some())]);
        if let Some(digest) = digest {
            text(&mut hash, digest)?;
        }
        text(
            &mut hash,
            &Zeroizing::new(document.editor_value().to_string()),
        )?;
        optional(&mut hash, context.api_base.as_ref())?;
        optional(&mut hash, context.api_key.as_ref())?;
        count(&mut hash, context.environment.entries().len())?;
        for (name, value) in context.environment.entries() {
            text(&mut hash, name.as_str())?;
            optional(&mut hash, value.as_ref())?;
        }
        let mut entries = context.registry.entries().iter().collect::<Vec<_>>();
        entries.sort_by(|left, right| left.id.cmp(&right.id));
        count(&mut hash, entries.len())?;
        for entry in entries {
            text(&mut hash, entry.id.as_str())?;
            optional(&mut hash, entry.api.as_ref())?;
            hash.update([u8::from(entry.local), u8::from(entry.keyless)]);
            text(&mut hash, "models")?;
            count(&mut hash, entry.models.len())?;
            for model in &entry.models {
                text(&mut hash, model.as_str())?;
            }
            text(&mut hash, "environment")?;
            count(&mut hash, entry.env.len())?;
            for name in &entry.env {
                text(&mut hash, name.as_str())?;
            }
        }
        Ok(Self(hash.finalize().into()))
    }
}
