//! Shared Git repository capture, fixed safety flags and explicit environment.

use super::super::command;
use super::profile::CapturedProfile;
use crate::{
    domain::Mode,
    domain::{CapturePolicy, ConfigRevision, OutputLimit, PolicyRevision, ToolCallLimit},
    error::CoreError,
    run::RunSettings,
    security::{CommandEnvironment, CommandInput, CommandSpec, ReadTarget, Workspace},
};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Path, PathBuf},
    time::Duration,
};

pub(super) struct Repository {
    workspace: Workspace,
    directory: PathBuf,
    identity: ReadTarget,
}
impl TryFrom<PathBuf> for Repository {
    type Error = CoreError;
    fn try_from(root: PathBuf) -> Result<Self, Self::Error> {
        crate::domain::check_path(&root)?;
        if !root.is_absolute() {
            return Err(CoreError::Rejected);
        }
        let workspace = Workspace::try_from(root)?;
        // Git interprets linked-worktree gitfiles; never discover a parent repo.
        let directory = workspace.path().join(".git").canonicalize()?;
        let identity = if directory.is_file() {
            ReadTarget::snapshot(directory.clone())?
        } else {
            ReadTarget::try_from(directory.clone())?
        };
        Ok(Self {
            workspace,
            directory,
            identity,
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
        self.command_with_profile(arguments, timeout, output, None)
    }
    pub(super) fn isolated_command(
        &self,
        arguments: Vec<OsString>,
        timeout: Option<Duration>,
        output: OutputLimit,
        profile: &CapturedProfile,
    ) -> Result<CommandSpec, CoreError> {
        self.command_with_profile(arguments, timeout, output, Some(profile))
    }
    fn command_with_profile(
        &self,
        arguments: Vec<OsString>,
        timeout: Option<Duration>,
        output: OutputLimit,
        profile: Option<&CapturedProfile>,
    ) -> Result<CommandSpec, CoreError> {
        self.workspace.revalidate()?;
        self.identity.revalidate()?;
        let program = command::executable("git")?;
        let binary_directory = program
            .parent()
            .ok_or(CoreError::Unavailable)?
            .as_os_str()
            .to_os_string();
        let git_dir = profile.map_or(self.directory.as_path(), CapturedProfile::worktree);
        let mut argv = read_options(git_dir, self.workspace.path());
        argv.extend(arguments);
        let environment = read_environment(binary_directory, profile);
        let mut command = CommandSpec::git_read(CommandInput {
            program,
            arguments: argv,
            working_directory: self.workspace.path().to_path_buf(),
            timeout,
            environment: CommandEnvironment::try_from(environment)?,
        })?
        .with_target_evidence(self.identity.duplicate()?)?
        .with_capture(CapturePolicy::Complete)
        .with_output_limit(output);
        if let Some(profile) = profile {
            command = profile.bind(command)?;
        }
        Ok(command)
    }
    pub(super) fn settings(&self, timeout: Option<Duration>) -> Result<RunSettings, CoreError> {
        match timeout {
            Some(timeout) => RunSettings::new(
                Mode::Ask,
                self.workspace.clone(),
                ToolCallLimit::default(),
                timeout,
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            ),
            None => Ok(RunSettings::persistent(
                Mode::Ask,
                self.workspace.clone(),
                ToolCallLimit::default(),
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            )),
        }
    }
}

/// Fixed global options for every read: no pager, fsmonitor, caches or submodules.
fn read_options(git_dir: &Path, worktree: &Path) -> Vec<OsString> {
    let mut directory = OsString::from("--git-dir=");
    directory.push(git_dir);
    let mut tree = OsString::from("--work-tree=");
    tree.push(worktree);
    vec![
        "--no-pager".into(),
        "--no-lazy-fetch".into(),
        "--literal-pathspecs".into(),
        directory,
        tree,
        "-c".into(),
        "core.fsmonitor=false".into(),
        "-c".into(),
        "core.untrackedCache=false".into(),
        "-c".into(),
        "diff.autoRefreshIndex=false".into(),
        "-c".into(),
        "submodule.recurse=false".into(),
        "-c".into(),
        "status.submoduleSummary=false".into(),
    ]
}

/// The read environment: git's own PATH, the user's config locations, and a
/// captured profile's private config, common dir and index when one is bound.
fn read_environment(
    binary_directory: OsString,
    profile: Option<&CapturedProfile>,
) -> BTreeMap<OsString, OsString> {
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
    if let Some(profile) = profile {
        environment.insert("GIT_CONFIG_NOSYSTEM".into(), "1".into());
        environment.insert("GIT_CONFIG_GLOBAL".into(), "/dev/null".into());
        environment.insert("GIT_ATTR_NOSYSTEM".into(), "1".into());
        environment.insert(
            "GIT_COMMON_DIR".into(),
            profile.common().as_os_str().to_owned(),
        );
        environment.insert(
            "GIT_INDEX_FILE".into(),
            profile.index().as_os_str().to_owned(),
        );
    }
    environment
}

impl Repository {
    /// The `workspace` field.
    pub(super) fn workspace(&self) -> &Workspace {
        &self.workspace
    }
}
