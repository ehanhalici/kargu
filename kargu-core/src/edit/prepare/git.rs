//! Fixed Git apply in an owned workspace. Original editor files are never written.
use super::{
    Artifact, PreparationResult, Prepared,
    artifact::{Batch, BatchFile},
    capture,
    inspection::{Inspection, PatchWork},
    types::{FileIndex, Part, RetainedBytes},
};
use crate::{
    application::{Mode, RunHandle, RunSettings, ToolOutcome},
    constants::limits,
    domain::{CapturePolicy, OutputLimit, ToolCallLimit, ToolName},
    edit::{EditError, patch::OperationKind, types::EditText},
    error::CoreError,
    process::{CapturedOutput, ProcessResult},
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
    workspace::command::Preparation,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    path::Path,
    time::Instant,
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

pub(crate) struct GitPreparation {
    pub command: CommandSpec,
    pub settings: RunSettings,
    pub tool: ToolName,
    pub report: PatchPrepared,
}
pub(crate) struct PatchPrepared {
    directory: TempDir,
    files: Vec<BatchFile>,
    hunks: crate::edit::types::HunkCount,
    deadline: Instant,
}
pub(crate) struct RunningPatch {
    prepared: PatchPrepared,
    cancel: CancellationToken,
}
impl PatchWork {
    pub(crate) fn prepare(mut self, context: &Preparation) -> Result<GitPreparation, CoreError> {
        context.check()?;
        let deadline = self.deadline.min(context.deadline());
        let root = Workspace::try_from(self.inspection.input.root.clone())?;
        if root.path().to_str().is_none() {
            return Err(EditError::InvalidPath.into());
        }
        let files = capture_files(
            &mut self.inspection,
            &root,
            context.cancellation(),
            deadline,
        )?;
        let directory = tempfile::Builder::new().prefix("kargu-edit-").tempdir()?;
        let prepared = build_command(&self.inspection, &files, &directory, deadline, context);
        match prepared {
            Ok((command, settings)) => Ok(GitPreparation {
                command,
                settings,
                tool: ToolName::try_from("edit_patch_prepare".to_owned())?,
                report: PatchPrepared {
                    directory,
                    files,
                    hunks: self.inspection.patch.hunk_count(),
                    deadline,
                },
            }),
            Err(error) => {
                directory.close().map_err(|_| CoreError::CleanupFailed)?;
                Err(error)
            }
        }
    }
}
fn capture_files(
    inspection: &mut Inspection,
    root: &Workspace,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<Vec<BatchFile>, CoreError> {
    let mut files = Vec::new();
    let mut paths = BTreeSet::new();
    let mut budget = RetainedBytes::default();
    for (index, target) in inspection.targets.iter().enumerate() {
        crate::security::file::checkpoint(cancel, deadline)?;
        let (evidence, disk) = capture::evidence(root, target.path.as_path(), cancel, deadline)?;
        if !paths.insert(evidence.canonical.clone()) {
            return Err(EditError::Conflict.into());
        }
        let live = inspection.documents.remove(&target.path);
        let base = if let Some(live) = &live {
            if live.disk != disk || live.dirty || live.read_only {
                return Err(EditError::Conflict.into());
            }
            let part = inspection
                .parts
                .remove(&Part::DocumentAt(FileIndex::try_from(index)?))
                .ok_or(EditError::InvalidEvidence)?;
            if !part.complete() {
                return Err(EditError::InvalidEvidence.into());
            }
            EditText::from_sensitive(part.text)?
        } else if evidence.existed() {
            capture::disk_text(&evidence, cancel, deadline)?
        } else {
            EditText::try_from(String::new())?
        };
        match target.initial {
            OperationKind::Add if evidence.existed() || !base.as_str().is_empty() => {
                return Err(EditError::Conflict.into());
            }
            OperationKind::Update | OperationKind::Delete if !evidence.existed() => {
                return Err(EditError::MissingTarget.into());
            }
            _ => {}
        }
        for op in inspection
            .patch
            .operations()
            .iter()
            .filter(|op| op.path() == &target.path)
        {
            for hunk in op.hunks() {
                crate::security::file::checkpoint(cancel, deadline)?;
                hunk.check_unique_context(&base)?;
            }
        }
        budget.include(&base)?;
        let proposed = EditText::try_from(String::new())?;
        files.push(BatchFile {
            kind: target.initial,
            hunks: target.hunks,
            proposal: Prepared {
                root: root.clone(),
                path: evidence.canonical.clone(),
                relative: target.path.clone(),
                base_hash: base.hash(),
                proposed_hash: proposed.hash(),
                evidence,
                disk,
                base,
                proposed,
                unchanged: false,
                live,
                config_revision: inspection.input.config_revision,
                policy_revision: inspection.input.policy_revision,
                review_mode: inspection.input.review_mode,
                save_policy: inspection.input.save_policy,
            },
        });
    }
    root.revalidate()?;
    if !inspection.documents.is_empty() || !inspection.parts.is_empty() {
        return Err(EditError::InvalidEvidence.into());
    }
    Ok(files)
}
fn build_command(
    inspection: &Inspection,
    files: &[BatchFile],
    directory: &TempDir,
    deadline: Instant,
    context: &Preparation,
) -> Result<(CommandSpec, RunSettings), CoreError> {
    let root = directory.path();
    std::fs::create_dir_all(root.join(".git/objects"))?;
    std::fs::create_dir_all(root.join(".git/refs/heads"))?;
    std::fs::create_dir_all(root.join(".git/info"))?;
    std::fs::write(root.join(".git/HEAD"), "ref: refs/heads/kargu\n")?;
    std::fs::write(
        root.join(".git/config"),
        "[core]\nrepositoryformatversion = 0\nbare = false\n",
    )?;
    // Highest-precedence private attributes neutralize even a patch targeting .gitattributes.
    std::fs::write(
        root.join(".git/info/attributes"),
        "* -text -crlf -eol -ident -filter -working-tree-encoding\n",
    )?;
    for file in files {
        context.check()?;
        if file.proposal.evidence.existed() {
            let path = root.join(file.proposal.relative.as_path());
            std::fs::create_dir_all(path.parent().ok_or(EditError::InvalidPath)?)?;
            std::fs::write(path, file.proposal.base.as_str())?;
        }
        file.proposal.root.revalidate()?;
        file.proposal.evidence.revalidate()?;
    }
    std::fs::write(root.join(".kargu.patch"), inspection.patch.normalized())?;
    let program = crate::workspace::command::executable("git")?;
    let environment = BTreeMap::from([
        (
            OsString::from("PATH"),
            program
                .parent()
                .ok_or(CoreError::Unavailable)?
                .as_os_str()
                .to_owned(),
        ),
        ("LC_ALL".into(), "C".into()),
        ("GIT_CONFIG_GLOBAL".into(), "/dev/null".into()),
        ("GIT_CONFIG_SYSTEM".into(), "/dev/null".into()),
        ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
        ("GIT_ATTR_NOSYSTEM".into(), "1".into()),
        ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        ("GIT_OPTIONAL_LOCKS".into(), "0".into()),
        (
            "GIT_INDEX_FILE".into(),
            root.join(".git/index").into_os_string(),
        ),
    ]);
    let mut gitdir = OsString::from("--git-dir=");
    gitdir.push(root.join(".git"));
    let mut worktree = OsString::from("--work-tree=");
    worktree.push(root);
    let timeout = deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or(CoreError::Deadline)?;
    let arguments = vec![
        "--no-pager".into(),
        "--no-lazy-fetch".into(),
        "--literal-pathspecs".into(),
        gitdir,
        worktree,
        "-c".into(),
        "core.attributesFile=/dev/null".into(),
        "-c".into(),
        "core.autocrlf=false".into(),
        "-c".into(),
        "core.safecrlf=false".into(),
        "-c".into(),
        "core.fsmonitor=false".into(),
        "-c".into(),
        "core.hooksPath=/dev/null".into(),
        "apply".into(),
        "--unidiff-zero".into(),
        "--whitespace=nowarn".into(),
        "--".into(),
        ".kargu.patch".into(),
    ];
    // This closed fixed-argv adapter mutates only its owned temporary workspace.
    let command = CommandSpec::git_read(CommandInput {
        program,
        arguments,
        working_directory: root.to_owned(),
        timeout: Some(timeout),
        environment: CommandEnvironment::try_from(environment)?,
    })?
    .with_capture(CapturePolicy::Complete)
    .with_output_limit(OutputLimit::try_from(limits::EDIT_PATCH_OUTPUT_BYTES)?)
    .with_snapshot_target(root.join(".kargu.patch"))?;
    // Git receives only private paths. Original source pins belong to the report,
    // which revalidates every file off-mailbox before publishing any proposal.
    let settings = RunSettings::new(
        Mode::Ask,
        Workspace::try_from(root.to_owned())?,
        ToolCallLimit::default(),
        timeout,
        inspection.input.config_revision,
        inspection.input.policy_revision,
    );
    Ok((command, settings?))
}
impl PatchPrepared {
    pub(crate) fn discard(self) -> Result<(), CoreError> {
        self.directory.close().map_err(|_| CoreError::CleanupFailed)
    }
    pub(crate) fn issued(self, run: &RunHandle) -> RunningPatch {
        RunningPatch {
            prepared: self,
            cancel: run.cancel_token(),
        }
    }
}
impl RunningPatch {
    pub(crate) fn complete(
        mut self,
        result: &ProcessResult,
        output: CapturedOutput,
    ) -> Result<PreparationResult, CoreError> {
        let prepared = if !result.cleanup_complete {
            Err(CoreError::CleanupFailed)
        } else if result.outcome != ToolOutcome::Ok || output.truncated {
            Err(EditError::PatchFailed.into())
        } else {
            self.read_result()
        };
        self.prepared
            .directory
            .close()
            .map_err(|_| CoreError::CleanupFailed)?;
        prepared
    }
    fn read_result(&mut self) -> Result<PreparationResult, CoreError> {
        let mut budget = RetainedBytes::default();
        for file in &self.prepared.files {
            budget.include(&file.proposal.base)?;
        }
        for file in &mut self.prepared.files {
            crate::security::file::checkpoint(&self.cancel, self.prepared.deadline)?;
            let path = self
                .prepared
                .directory
                .path()
                .join(file.proposal.relative.as_path());
            let proposed = match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_file() => {
                    file.kind = if file.proposal.evidence.existed() {
                        OperationKind::Update
                    } else {
                        OperationKind::Add
                    };
                    read_private(&path, &self.cancel, self.prepared.deadline)?
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    file.kind = OperationKind::Delete;
                    EditText::try_from(String::new())?
                }
                _ => return Err(EditError::InvalidEvidence.into()),
            };
            budget.include(&proposed)?;
            file.proposal.unchanged = if file.proposal.evidence.existed() {
                file.kind != OperationKind::Delete
                    && file.proposal.base.as_str() == proposed.as_str()
            } else {
                file.kind == OperationKind::Delete
            };
            file.proposal.proposed_hash = proposed.hash();
            file.proposal.proposed = proposed;
            file.proposal.root.revalidate()?;
            file.proposal.evidence.revalidate()?;
        }
        let files = std::mem::take(&mut self.prepared.files);
        Ok(PreparationResult::Complete(Artifact::Batch(Box::new(
            Batch {
                files,
                hunks: self.prepared.hunks,
            },
        ))))
    }
}
fn read_private(
    path: &Path,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<EditText, CoreError> {
    use crate::security::file::PinnedFile;
    use zeroize::Zeroizing;
    let file = PinnedFile::open(path, path.canonicalize()?, cancel, deadline)?;
    if file.size() > limits::EDIT_TEXT_BYTES as u64 {
        return Err(EditError::Limit.into());
    }
    let mut reader = file.reader()?;
    let mut bytes = Zeroizing::new(Vec::new());
    let mut chunk = Zeroizing::new([0; 4096]);
    loop {
        let count = reader.read(chunk.as_mut_slice(), cancel, deadline)?;
        if bytes.len().checked_add(count).ok_or(EditError::Limit)? > limits::EDIT_TEXT_BYTES {
            return Err(EditError::Limit.into());
        }
        bytes.extend_from_slice(chunk.get(..count).ok_or(EditError::Limit)?);
        if count == 0 {
            break;
        }
    }
    reader.finish()?;
    match String::from_utf8(std::mem::take(&mut *bytes)) {
        Ok(text) => EditText::try_from(text).map_err(CoreError::from),
        Err(error) => {
            let _sensitive = Zeroizing::new(error.into_bytes());
            Err(EditError::InvalidEvidence.into())
        }
    }
}
