//! Git CLI adapters. Repository mechanics remain Git's responsibility.

mod status;
pub(crate) use status::StatusReport;

use super::command::{self, ReadTimeout};
use crate::{
    application::{Mode, RunSettings},
    constants::limits,
    domain::{CapturePolicy, ConfigRevision, OutputLimit, PolicyRevision, ToolCallLimit},
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Component, PathBuf},
};

/// Repository-root scoped fixed-argv status, not arbitrary Git arguments.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitStatusInput {
    root: PathBuf,
    #[serde(default)]
    output_bytes: OutputLimit,
    #[serde(default)]
    timeout_ms: ReadTimeout,
}
impl GitStatusInput {
    pub(crate) fn prepare(self) -> Result<(CommandSpec, RunSettings, StatusReport), CoreError> {
        if !self.root.is_absolute()
            || self.root.as_os_str().len() > limits::SEARCH_PATH_BYTES
            || self.root.components().any(|c| c == Component::ParentDir)
        {
            return Err(CoreError::Rejected);
        }
        let workspace = Workspace::try_from(self.root)?;
        // A nested non-repository root must not silently discover a parent's repo.
        // Git itself interprets ordinary .git directories and linked-worktree gitfiles.
        let git_directory = workspace.path().join(".git").canonicalize()?;
        let program = command::executable("git")?;
        let binary_directory = program
            .parent()
            .ok_or(CoreError::Unavailable)?
            .as_os_str()
            .to_os_string();
        let mut directory_arg = OsString::from("--git-dir=");
        directory_arg.push(&git_directory);
        let mut worktree_arg = OsString::from("--work-tree=");
        worktree_arg.push(workspace.path());
        let timeout = self.timeout_ms.duration();
        let mut environment = BTreeMap::from([
            ("PATH".into(), binary_directory),
            ("LC_ALL".into(), "C".into()),
            ("GIT_OPTIONAL_LOCKS".into(), "0".into()),
            ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        ]);
        // Preserve host ignore/config sources without inheriting GIT_DIR,
        // GIT_WORK_TREE, credentials or arbitrary environment injection.
        for key in [
            "HOME",
            "XDG_CONFIG_HOME",
            "GIT_CONFIG_GLOBAL",
            "GIT_CONFIG_SYSTEM",
            "GIT_CONFIG_NOSYSTEM",
        ] {
            if let Some(value) = std::env::var_os(key) {
                environment.insert(key.into(), value);
            }
        }
        let command = CommandSpec::git_status(CommandInput {
            program,
            arguments: vec![
                "--no-pager".into(),
                directory_arg,
                worktree_arg,
                "-c".into(),
                "core.fsmonitor=false".into(),
                "-c".into(),
                "core.untrackedCache=false".into(),
                "status".into(),
                "--porcelain=v1".into(),
                "-b".into(),
                "-z".into(),
            ],
            working_directory: workspace.path().to_path_buf(),
            timeout,
            environment: CommandEnvironment::try_from(environment)?,
        })?
        .with_read_target(git_directory)?
        .with_capture(CapturePolicy::Complete)
        .with_output_limit(self.output_bytes);
        let report = StatusReport::new(workspace.path().to_path_buf(), self.output_bytes);
        let settings = match timeout {
            Some(timeout) => RunSettings::new(
                Mode::Ask,
                workspace,
                ToolCallLimit::default(),
                timeout,
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            )?,
            None => RunSettings::persistent(
                Mode::Ask,
                workspace,
                ToolCallLimit::default(),
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            ),
        };
        Ok((command, settings, report))
    }
}
