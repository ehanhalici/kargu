//! Closed, helper-free Git log/ref queries. Git owns algorithms and text output.

use super::{super::command::ReadTimeout, repository::Repository};
use crate::{
    application::{RunSettings, ToolOutcome},
    domain::{OutputLimit, ToolName},
    error::CoreError,
    security::CommandSpec,
};
use serde::Deserialize;
use std::{ffi::OsString, path::PathBuf};

#[derive(Deserialize)]
#[serde(try_from = "u64")]
struct CommitLimit(u64);
impl TryFrom<u64> for CommitLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        if !(1..=10000).contains(&value) {
            return Err(CoreError::Limit);
        }
        Ok(Self(value))
    }
}
impl Default for CommitLimit {
    fn default() -> Self {
        Self(10)
    }
}

#[derive(Deserialize)]
#[serde(try_from = "PathBuf")]
struct RepositoryPath(PathBuf);
impl TryFrom<PathBuf> for RepositoryPath {
    type Error = CoreError;
    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        super::super::command::validate_path(&path)?;
        if path.as_os_str().is_empty() {
            return Err(CoreError::InvalidValue { field: "GitPath" });
        }
        Ok(Self(path))
    }
}
impl RepositoryPath {
    fn capture(self, repository: &Repository) -> Result<(OsString, PathBuf), CoreError> {
        let root = repository.workspace.path();
        let original = root.join(self.0);
        let relative = original
            .strip_prefix(root)
            .map_err(|_| CoreError::Rejected)?
            .as_os_str()
            .to_os_string();
        let relative = if relative.is_empty() {
            OsString::from(".")
        } else {
            relative
        };
        let mut ancestor = original.as_path();
        loop {
            match ancestor.canonicalize() {
                Ok(path) if path.starts_with(root) => return Ok((relative, path)),
                Ok(_) => return Err(CoreError::Rejected),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    ancestor = ancestor.parent().ok_or(CoreError::Rejected)?;
                }
                Err(error) => return Err(error.into()),
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Query {
    Log {
        #[serde(default)]
        max_count: CommitLimit,
        path: Option<RepositoryPath>,
    },
    Branches {},
    Stashes {},
}
/// Closed log/branch/stash query; never arbitrary Git argv or helper authority.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitReadInput {
    root: PathBuf,
    query: Query,
    #[serde(default)]
    output_bytes: OutputLimit,
    #[serde(default)]
    timeout_ms: ReadTimeout,
}
pub(crate) struct GitReadReport {
    output: OutputLimit,
    empty: &'static str,
}
impl GitReadReport {
    pub(crate) fn output_limit(&self) -> OutputLimit {
        self.output
    }
    pub(crate) fn text(
        &self,
        stdout: &[u8],
        stderr: &[u8],
        outcome: ToolOutcome,
    ) -> Result<String, CoreError> {
        let text = std::str::from_utf8(stdout)
            .map_err(|_| CoreError::InvalidToolOutput)?
            .trim();
        let diagnostic = std::str::from_utf8(stderr)
            .map_err(|_| CoreError::InvalidToolOutput)?
            .trim();
        if outcome == ToolOutcome::Ok {
            Ok(if text.is_empty() {
                self.empty.to_owned()
            } else {
                text.to_owned()
            })
        } else {
            Ok(format!("{text}\n{diagnostic}"))
        }
    }
}
impl GitReadInput {
    pub(crate) fn prepare(
        self,
    ) -> Result<(CommandSpec, RunSettings, ToolName, GitReadReport), CoreError> {
        let repository = Repository::try_from(self.root)?;
        let (name, empty, mut arguments, path) = match self.query {
            Query::Log { max_count, path } => (
                "git_log",
                "(no commits found)",
                vec![
                    "log".into(),
                    format!("-n{}", max_count.0).into(),
                    "--oneline".into(),
                    "--graph".into(),
                    "--decorate".into(),
                    "--no-color".into(),
                    "--no-show-signature".into(),
                    "--no-patch".into(),
                ],
                path,
            ),
            Query::Branches {} => (
                "git_branches",
                "",
                vec!["branch".into(), "-a".into(), "--no-color".into()],
                None,
            ),
            Query::Stashes {} => (
                "git_stashes",
                "(no stash entries)",
                vec![
                    "stash".into(),
                    "list".into(),
                    "--no-color".into(),
                    "--no-show-signature".into(),
                    "--no-patch".into(),
                ],
                None,
            ),
        };
        let target = path.map(|path| path.capture(&repository)).transpose()?;
        arguments.push("--".into());
        if let Some((relative, _)) = &target {
            arguments.push(relative.clone());
        }
        let timeout = self.timeout_ms.duration();
        let mut command = repository.command(arguments, timeout, self.output_bytes)?;
        if let Some((_, target)) = target {
            command = command.with_read_target(target)?;
        }
        let report = GitReadReport {
            output: self.output_bytes,
            empty,
        };
        Ok((
            command,
            repository.settings(timeout)?,
            ToolName::try_from(name.to_owned())?,
            report,
        ))
    }
}
