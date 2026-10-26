//! Strict command DTO capture. Filesystem preparation runs off the mailbox.

use super::reply::Reply;
use crate::domain::StderrPolicy;
use crate::{
    application::{Mode, RunPurpose, RunSettings},
    constants::timeouts,
    domain::{
        ConfigRevision, ExecutionTimeout, IdleTimeout, OutputLimit, OutputRetention,
        PolicyRevision, ToolCallLimit, ToolName,
    },
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Path, PathBuf},
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
    #[serde(default)]
    idle_timeout_ms: IdleTimeout,
    #[serde(default)]
    output_bytes: OutputLimit,
    #[serde(default)]
    stderr: StderrPolicy,
    environment: BTreeMap<String, String>,
    config_revision: ConfigRevision,
    policy_revision: PolicyRevision,
}

#[derive(Deserialize)]
#[serde(try_from = "Option<u64>")]
struct CommandTimeout(ExecutionTimeout);
impl TryFrom<Option<u64>> for CommandTimeout {
    type Error = CoreError;
    fn try_from(value: Option<u64>) -> Result<Self, CoreError> {
        if value.is_some_and(|n| n == 0 || n > 86_400_000) {
            return Err(CoreError::InvalidValue {
                field: "CommandTimeout",
            });
        }
        Ok(Self(ExecutionTimeout::try_from(
            value.map(Duration::from_millis),
        )?))
    }
}

pub(super) struct Prepared {
    pub tool: ToolName,
    pub command: CommandSpec,
    pub settings: RunSettings,
    pub reply: Reply,
}

impl ExecuteInput {
    pub fn prepare(self, purpose: RunPurpose) -> Result<Prepared, CoreError> {
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
        let timeout = self.timeout_ms.0.duration();
        if timeout.is_none() && purpose == RunPurpose::AgentTurn {
            return Err(CoreError::InvalidValue {
                field: "CommandTimeout",
            });
        }
        let settings = if let Some(timeout) = timeout {
            RunSettings::new(
                Mode::Agent,
                workspace,
                ToolCallLimit::default(),
                timeout
                    .checked_add(timeouts::APPROVAL)
                    .ok_or(CoreError::ArithmeticOverflow)?,
                self.config_revision,
                self.policy_revision,
            )?
        } else {
            RunSettings::persistent(
                Mode::Agent,
                workspace,
                ToolCallLimit::default(),
                self.config_revision,
                self.policy_revision,
            )
        };
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
        })?
        .with_retention(if purpose == RunPurpose::ProcessJob {
            OutputRetention::Tail
        } else {
            OutputRetention::Prefix
        })
        .with_output_limit(self.output_bytes)
        .with_idle_timeout(self.idle_timeout_ms)
        .with_stderr(self.stderr);
        if command.program.to_str().is_none() || command.cwd.path().to_str().is_none() {
            return Err(CoreError::InvalidValue {
                field: "CommandPathEncoding",
            });
        }
        Ok(Prepared {
            reply: Reply::Command,
            command,
            settings,
            tool: ToolName::try_from("bash".to_owned())?,
        })
    }
}

pub(crate) use crate::workspace::command::validate_path;
