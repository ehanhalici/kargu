//! Owned native path/stat/regular-file capture; no editor or original disk writes.
use super::{
    Prepared, Work,
    types::{DiskState, DiskVersion, Intent, Part},
};
use crate::{
    constants::limits,
    edit::{
        EditError, proposal,
        types::{EditPath, EditText},
    },
    error::CoreError,
    security::{
        ReadTarget, Workspace,
        file::{PinnedFile, checkpoint},
    },
    workspace::file::decode::Decoder,
};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

pub(super) struct Evidence {
    original: PathBuf,
    pub(super) canonical: PathBuf,
    pin: ReadTarget,
    exists: bool,
}
impl Evidence {
    pub(super) fn existed(&self) -> bool {
        self.exists
    }
    pub(super) fn revalidate(&self) -> Result<(), CoreError> {
        self.pin.revalidate()?;
        if self.exists {
            if self
                .original
                .canonicalize()
                .map_err(|_| CoreError::WorkspaceChanged)?
                != self.canonical
            {
                return Err(CoreError::WorkspaceChanged);
            }
        } else {
            if !std::fs::symlink_metadata(&self.original)
                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
            {
                return Err(CoreError::WorkspaceChanged);
            }
            let canonical = resolve_missing(&self.original)?.0;
            if canonical != self.canonical {
                return Err(CoreError::WorkspaceChanged);
            }
        }
        Ok(())
    }
}
fn resolve_missing(path: &Path) -> Result<(PathBuf, PathBuf), CoreError> {
    let mut ancestor = path;
    let mut missing = Vec::new();
    loop {
        match ancestor.canonicalize() {
            Ok(real) => {
                if !real.is_dir() {
                    return Err(CoreError::Rejected);
                }
                let mut canonical = real.clone();
                for name in missing.iter().rev() {
                    canonical.push(name);
                }
                return Ok((canonical, real));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Broken links are not evidence of absence.
                if std::fs::symlink_metadata(ancestor).is_ok() {
                    return Err(CoreError::Rejected);
                }
                missing.push(
                    ancestor
                        .file_name()
                        .ok_or(CoreError::Rejected)?
                        .to_os_string(),
                );
                ancestor = ancestor.parent().ok_or(CoreError::Rejected)?;
            }
            Err(error) => return Err(error.into()),
        }
    }
}
pub(super) fn evidence(
    root: &Workspace,
    path: &Path,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<(Evidence, DiskState), CoreError> {
    checkpoint(cancel, deadline)?;
    let original = root.path().join(path);
    let (canonical, pin, exists, disk) = match std::fs::symlink_metadata(&original) {
        Ok(_) => {
            let canonical = original.canonicalize()?;
            if !canonical.starts_with(root.path()) {
                return Err(CoreError::Rejected);
            }
            let pin = ReadTarget::snapshot(canonical.clone())?;
            let metadata = pin.metadata()?;
            if !metadata.is_file() {
                return Err(CoreError::Rejected);
            }
            let disk = DiskState::File {
                version: DiskVersion::capture(&metadata)?,
            };
            (canonical, pin, true, disk)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let (canonical, ancestor) = resolve_missing(&original)?;
            if !canonical.starts_with(root.path()) || !ancestor.starts_with(root.path()) {
                return Err(CoreError::Rejected);
            }
            (
                canonical,
                ReadTarget::try_from(ancestor)?,
                false,
                DiskState::Absent {},
            )
        }
        Err(error) => return Err(error.into()),
    };
    // Lexical request checks alone cannot protect a symlink into metadata.
    let relative = canonical
        .strip_prefix(root.path())
        .map_err(|_| CoreError::Rejected)?;
    EditPath::try_from(relative.to_str().ok_or(EditError::InvalidPath)?.to_owned())?;
    let evidence = Evidence {
        original,
        canonical,
        pin,
        exists,
    };
    evidence.revalidate()?;
    Ok((evidence, disk))
}
pub(super) struct DiskContents {
    pub text: EditText,
    pub raw_digest: crate::edit::types::CaptureDigest,
}
pub(super) fn disk_text(
    evidence: &Evidence,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<EditText, CoreError> {
    Ok(disk_contents(evidence, cancel, deadline)?.text)
}
pub(super) fn disk_contents(
    evidence: &Evidence,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<DiskContents, CoreError> {
    let file = PinnedFile::open(
        &evidence.original,
        evidence.canonical.clone(),
        cancel,
        deadline,
    )?;
    if file.size() > limits::EDIT_DISK_BYTES as u64 {
        return Err(CoreError::Limit);
    }
    let mut reader = file.reader()?;
    let mut decoder = Decoder::default();
    let mut digest = Sha256::new();
    let mut text = Zeroizing::new(String::new());
    let mut bytes = Zeroizing::new([0; 4096]);
    let mut consumed = 0usize;
    loop {
        let count = reader.read(bytes.as_mut_slice(), cancel, deadline)?;
        consumed = consumed.checked_add(count).ok_or(CoreError::Limit)?;
        if consumed > limits::EDIT_DISK_BYTES {
            return Err(CoreError::Limit);
        }
        digest.update(bytes.get(..count).ok_or(CoreError::Limit)?);
        let decoded = decoder.decode(bytes.get(..count).ok_or(CoreError::Limit)?, count == 0)?;
        if text
            .len()
            .checked_add(decoded.len())
            .ok_or(CoreError::Limit)?
            > limits::EDIT_TEXT_BYTES
        {
            return Err(CoreError::Limit);
        }
        text.push_str(&decoded);
        if count == 0 {
            break;
        }
    }
    reader.finish()?;
    // Editor decoded text represents CRLF by LF; original coding is separate evidence.
    Ok(DiskContents {
        text: EditText::try_from(text.replace("\r\n", "\n"))?,
        raw_digest: crate::edit::types::CaptureDigest::try_from(format!(
            "{:x}",
            digest.finalize()
        ))?,
    })
}
impl Work {
    pub(crate) fn execute(
        mut self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<super::PreparationResult, CoreError> {
        let deadline = deadline.min(self.deadline);
        checkpoint(cancel, deadline)?;
        if matches!(self.input.intent, Intent::Patch { .. }) {
            let patch = crate::edit::patch::UnifiedPatch::try_from(self.take(Part::Patch)?)?;
            checkpoint(cancel, deadline)?;
            return Ok(super::PreparationResult::Inspected(Box::new(
                super::inspection::Inspection::new(self.input, patch)?,
            )));
        }
        let relative = self
            .input
            .intent
            .path()
            .ok_or(EditError::InvalidEvidence)?
            .clone();
        let root = Workspace::try_from(self.input.root.clone())?;
        let (evidence, disk) = evidence(&root, relative.as_path(), cancel, deadline)?;
        if root.path().to_str().is_none() || evidence.canonical.to_str().is_none() {
            return Err(EditError::InvalidPath.into());
        }
        let base = if let Some(live) = &self.input.live {
            if live.dirty || live.read_only || live.disk != disk {
                return Err(EditError::Conflict.into());
            }
            self.take(Part::Document)?
        } else if evidence.exists {
            disk_text(&evidence, cancel, deadline)?
        } else {
            EditText::try_from(String::new())?
        };
        let new = self.take(Part::New)?;
        let proposed = match &self.input.intent {
            Intent::Write { .. } => new,
            Intent::Patch { .. } => return Err(EditError::InvalidEvidence.into()),
            Intent::Replace { .. } => {
                if !evidence.exists && self.input.live.is_none() {
                    return Err(EditError::MissingTarget.into());
                }
                let old = self.take(Part::Old)?;
                proposal::replace(&base, &old, &new)?
            }
        };
        checkpoint(cancel, deadline)?;
        root.revalidate()?;
        evidence.revalidate()?;
        let base_hash = base.hash();
        let proposed_hash = proposed.hash();
        let kind = if evidence.existed() {
            crate::edit::patch::OperationKind::Update
        } else {
            crate::edit::patch::OperationKind::Add
        };
        let unchanged = super::artifact::unchanged(
            &evidence,
            self.input.live.as_ref(),
            kind,
            self.input.save_policy,
            base_hash,
            proposed_hash,
        );
        Ok(super::PreparationResult::Complete(super::Artifact::File(
            Box::new(Prepared {
                base_hash,
                proposed_hash,
                unchanged,
                root,
                path: evidence.canonical.clone(),
                relative,
                disk,
                evidence,
                base: base.into(),
                proposed: proposed.into(),
                live: self.input.live,
                config_revision: self.input.config_revision,
                policy_revision: self.input.policy_revision,
                review_mode: self.input.review_mode,
                save_policy: self.input.save_policy,
            }),
        )))
    }
}
