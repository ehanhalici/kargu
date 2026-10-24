//! Strict command DTO capture. Filesystem preparation runs off the mailbox.

use crate::{
    application::{Mode, RunSettings},
    constants::{limits, timeouts},
    domain::{ConfigRevision, PolicyRevision, ToolCallLimit, ToolName},
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Component, Path, PathBuf},
    time::Duration,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ExecuteInput {
    root: PathBuf,
    mode: Mode,
    program: PathBuf,
    arguments: Vec<String>,
    cwd: Option<PathBuf>,
    timeout_ms: CommandTimeout,
    environment: BTreeMap<String, String>,
    config_revision: ConfigRevision,
    policy_revision: PolicyRevision,
}

#[derive(Deserialize)]
#[serde(try_from = "u64")]
struct CommandTimeout(Duration);
impl TryFrom<u64> for CommandTimeout {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 || value > 86_400_000 {
            return Err(CoreError::InvalidValue {
                field: "CommandTimeout",
            });
        }
        Ok(Self(Duration::from_millis(value)))
    }
}

pub(super) struct Prepared {
    pub tool: ToolName,
    pub command: CommandSpec,
    pub settings: RunSettings,
}

impl ExecuteInput {
    pub fn prepare(self) -> Result<Prepared, CoreError> {
        if self.mode != Mode::Agent {
            return Err(CoreError::Rejected);
        }
        validate_path(&self.root)?;
        let cwd = self.cwd.as_deref().unwrap_or(Path::new("."));
        validate_path(cwd)?;
        if !self.root.is_absolute() {
            return Err(CoreError::Rejected);
        }
        let workspace = Workspace::try_from(self.root)?;
        let cwd = workspace.path().join(cwd).canonicalize()?;
        if !cwd.starts_with(workspace.path()) {
            return Err(CoreError::Rejected);
        }
        let timeout = self.timeout_ms.0;
        let settings = RunSettings::new(
            Mode::Agent,
            workspace,
            ToolCallLimit::default(),
            timeout
                .checked_add(timeouts::APPROVAL)
                .ok_or(CoreError::ArithmeticOverflow)?,
            self.config_revision,
            self.policy_revision,
        )?;
        let environment: BTreeMap<OsString, OsString> = self
            .environment
            .into_iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect();
        let command = CommandSpec::try_from(CommandInput {
            program: self.program,
            arguments: self.arguments.into_iter().map(OsString::from).collect(),
            working_directory: cwd,
            timeout,
            environment: CommandEnvironment::try_from(environment)?,
        })?;
        if command.program.to_str().is_none() || command.cwd.path().to_str().is_none() {
            return Err(CoreError::InvalidValue {
                field: "CommandPathEncoding",
            });
        }
        Ok(Prepared {
            command,
            settings,
            tool: ToolName::try_from("bash".to_owned())?,
        })
    }
}

pub(crate) fn validate_path(path: &Path) -> Result<(), CoreError> {
    if path.as_os_str().len() > limits::SEARCH_PATH_BYTES
        || path.components().any(|c| c == Component::ParentDir)
    {
        return Err(CoreError::Rejected);
    }
    Ok(())
}
