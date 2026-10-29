//! Complete live-document witnesses, followed by bounded native all-file revalidation.
use super::{
    Artifact, Prepared,
    types::{FileCount, FileIndex, LiveDocument},
};
use crate::{
    edit::{
        EditError,
        types::{CaptureDigest, ContentHash},
    },
    error::CoreError,
    security::file::checkpoint,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, sync::Arc, time::Instant};
use tokio_util::sync::CancellationToken;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PreflightFile {
    file: FileIndex,
    base_hash: ContentHash,
    document: LiveDocument,
}
#[derive(Default)]
pub(crate) struct PreflightSet {
    files: BTreeMap<FileIndex, PreflightFile>,
    checked: FileCount,
}
#[derive(Serialize)]
pub(crate) struct PreflightProgress {
    file: FileIndex,
    files_checked: FileCount,
    files_total: FileCount,
    pub(crate) ready: bool,
}
pub(crate) struct PreflightWork {
    witnesses: PreflightSet,
    artifact: Arc<Artifact>,
    deadline: Instant,
}
pub(crate) struct ReadyPreflight {
    witnesses: PreflightSet,
    total: FileCount,
    digest: CaptureDigest,
}
pub(super) fn count(artifact: &Artifact) -> usize {
    match artifact {
        Artifact::File(_) => 1,
        Artifact::Batch(batch) => batch.files.len(),
    }
}
pub(super) fn file(artifact: &Artifact, index: FileIndex) -> Result<&Prepared, CoreError> {
    match artifact {
        Artifact::File(prepared) if index.get() == 0 => Ok(prepared),
        Artifact::Batch(batch) => batch
            .files
            .get(index.get())
            .map(|file| &file.proposal)
            .ok_or_else(|| EditError::InvalidEvidence.into()),
        _ => Err(EditError::InvalidEvidence.into()),
    }
}
impl PreflightSet {
    pub(crate) fn would_finish(&self, artifact: &Artifact) -> bool {
        self.files.len().checked_add(1) == Some(count(artifact))
    }
    pub(crate) fn record(
        &mut self,
        artifact: &Artifact,
        input: PreflightFile,
    ) -> Result<PreflightProgress, CoreError> {
        let prepared = file(artifact, input.file)?;
        if self.files.contains_key(&input.file) {
            return Err(CoreError::AlreadyCompleted);
        }
        let document = &input.document;
        if self
            .files
            .values()
            .any(|witness| witness.document.id == document.id)
        {
            return Err(EditError::Conflict.into());
        }
        if input.base_hash != prepared.base_hash
            || document.bytes.get() != prepared.base.as_str().len()
            || document.disk != prepared.disk
            || document.dirty != prepared.live.as_ref().is_some_and(|live| live.dirty)
            || document.read_only
        {
            return Err(EditError::Conflict.into());
        }
        if let Some(captured) = &prepared.live
            && (captured.id != document.id
                || captured.tick != document.tick
                || captured.coding != document.coding)
        {
            return Err(EditError::Conflict.into());
        }
        let index = input.file;
        let checked = FileCount::try_from(
            self.files
                .len()
                .checked_add(1)
                .ok_or(CoreError::ArithmeticOverflow)?,
        )?;
        let total = FileCount::try_from(count(artifact))?;
        self.files.insert(index, input);
        self.checked = checked;
        Ok(PreflightProgress {
            file: index,
            files_checked: checked,
            files_total: total,
            ready: self.files.len() == count(artifact),
        })
    }
    pub(crate) fn into_work(
        self,
        artifact: Arc<Artifact>,
        deadline: Instant,
    ) -> Result<PreflightWork, CoreError> {
        if self.files.len() != count(&artifact) {
            return Err(EditError::InvalidEvidence.into());
        }
        Ok(PreflightWork {
            witnesses: self,
            artifact,
            deadline,
        })
    }
}
impl PreflightWork {
    pub(crate) fn execute(self, cancel: &CancellationToken) -> Result<ReadyPreflight, CoreError> {
        checkpoint(cancel, self.deadline)?;
        for index in self.witnesses.files.keys() {
            checkpoint(cancel, self.deadline)?;
            let prepared = file(&self.artifact, *index)?;
            prepared.root.revalidate()?;
            prepared.evidence.revalidate()?;
        }
        let facts: Vec<_> = self.witnesses.files.values().collect();
        let encoded = serde_json::to_vec(&facts).map_err(|_| CoreError::InvalidToolOutput)?;
        let digest = CaptureDigest::capture(&encoded);
        checkpoint(cancel, self.deadline)?;
        Ok(ReadyPreflight {
            witnesses: self.witnesses,
            total: FileCount::try_from(count(&self.artifact))?,
            digest,
        })
    }
}
impl ReadyPreflight {
    pub(super) fn document(&self, index: FileIndex) -> Result<&LiveDocument, CoreError> {
        self.witnesses
            .files
            .get(&index)
            .map(|file| &file.document)
            .ok_or_else(|| EditError::InvalidEvidence.into())
    }
    pub(crate) fn digest(&self) -> CaptureDigest {
        self.digest
    }
    pub(crate) fn revalidate(
        &self,
        artifact: &Artifact,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<(), CoreError> {
        for index in self.witnesses.files.keys() {
            checkpoint(cancel, deadline)?;
            let prepared = file(artifact, *index)?;
            prepared.root.revalidate()?;
            prepared.evidence.revalidate()?;
        }
        checkpoint(cancel, deadline)
    }
    pub(crate) fn descriptor(&self) -> Value {
        json!({"ready":true,"files_checked":self.witnesses.checked,"files_total":self.total,"preflight_digest":self.digest})
    }
}
