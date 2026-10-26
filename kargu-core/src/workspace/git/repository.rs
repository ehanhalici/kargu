//! Shared Git repository capture, fixed safety flags and explicit environment.

use super::super::command;
use crate::{
    application::{Mode, RunSettings},
    domain::{CapturePolicy, ConfigRevision, OutputLimit, PolicyRevision, ToolCallLimit},
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use std::{collections::BTreeMap, ffi::OsString, path::PathBuf, time::Duration};

pub(super) struct Repository {
    pub(super) workspace: Workspace,
    directory: PathBuf,
}
impl TryFrom<PathBuf> for Repository {
    type Error = CoreError;
    fn try_from(root: PathBuf) -> Result<Self, Self::Error> {
        command::validate_path(&root)?;
        if !root.is_absolute() {
            return Err(CoreError::Rejected);
        }
        let workspace = Workspace::try_from(root)?;
        // Git interprets linked-worktree gitfiles; never discover a parent repo.
        let directory = workspace.path().join(".git").canonicalize()?;
        Ok(Self {
            workspace,
            directory,
        })
    }
}
impl Repository {
    pub(super) fn command(
        &self,
        arguments: Vec<OsString>,
        timeout: Option<Duration>,
        output: OutputLimit,
    ) -> Result<CommandSpec, CoreError> {
        let program = command::executable("git")?;
        let binary_directory = program
            .parent()
            .ok_or(CoreError::Unavailable)?
            .as_os_str()
            .to_os_string();
        let mut directory = OsString::from("--git-dir=");
        directory.push(&self.directory);
        let mut worktree = OsString::from("--work-tree=");
        worktree.push(self.workspace.path());
        let mut argv: Vec<OsString> = vec![
            "--no-pager".into(),
            "--no-lazy-fetch".into(),
            "--literal-pathspecs".into(),
            directory,
            worktree,
            "-c".into(),
            "core.fsmonitor=false".into(),
            "-c".into(),
            "core.untrackedCache=false".into(),
        ];
        argv.extend(arguments);
        let mut environment = BTreeMap::from([
            ("PATH".into(), binary_directory),
            ("LC_ALL".into(), "C".into()),
            ("GIT_OPTIONAL_LOCKS".into(), "0".into()),
            ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        ]);
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
        Ok(CommandSpec::git_read(CommandInput {
            program,
            arguments: argv,
            working_directory: self.workspace.path().to_path_buf(),
            timeout,
            environment: CommandEnvironment::try_from(environment)?,
        })?
        .with_read_target(self.directory.clone())?
        .with_capture(CapturePolicy::Complete)
        .with_output_limit(output))
    }
    pub(super) fn settings(self, timeout: Option<Duration>) -> Result<RunSettings, CoreError> {
        match timeout {
            Some(timeout) => RunSettings::new(
                Mode::Ask,
                self.workspace,
                ToolCallLimit::default(),
                timeout,
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            ),
            None => Ok(RunSettings::persistent(
                Mode::Ask,
                self.workspace,
                ToolCallLimit::default(),
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            )),
        }
    }
}
