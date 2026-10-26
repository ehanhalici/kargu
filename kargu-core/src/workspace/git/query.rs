//! Closed Git read intents; immutable safe configuration for worktree consumers.

mod capture;
mod execute;
pub(crate) use capture::GitReadPreparation;

use super::super::command::Preparation;
use super::{super::command::ReadTimeout, repository::Repository};
use super::{
    profile::{CapturedProfile, PreparedProfile, RunningProfile},
    status::StatusReport,
};
use crate::{
    application::{RunSettings, ToolOutcome},
    domain::{OutputLimit, ToolName},
    error::CoreError,
    security::CommandSpec,
};
use serde::Deserialize;
use std::{
    ffi::OsString,
    path::PathBuf,
    time::{Duration, Instant},
};

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
        if path.as_os_str().is_empty() || path.as_os_str().as_encoded_bytes().contains(&0) {
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
#[serde(try_from = "String")]
struct Revision(String);
impl TryFrom<String> for Revision {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let value = value.trim();
        if value.is_empty()
            || value.len() > 4096
            || value.starts_with('-')
            || value.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return Err(CoreError::InvalidValue {
                field: "GitRevision",
            });
        }
        Ok(Self(value.to_owned()))
    }
}
#[derive(Deserialize)]
#[serde(try_from = "u64")]
struct BlameLine(u64);
impl TryFrom<u64> for BlameLine {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 || value > i64::MAX as u64 {
            return Err(CoreError::InvalidValue { field: "BlameLine" });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum QueryDto {
    Log {
        #[serde(default)]
        max_count: CommitLimit,
        path: Option<RepositoryPath>,
    },
    Branches {},
    Stashes {},
    Diff {
        #[serde(default)]
        staged: bool,
        path: Option<RepositoryPath>,
        commit: Option<Revision>,
    },
    Blame {
        path: RepositoryPath,
        from: Option<BlameLine>,
        to: Option<BlameLine>,
    },
}
enum BlameRange {
    All,
    Lines {
        from: BlameLine,
        to: Option<BlameLine>,
    },
}
impl TryFrom<(Option<BlameLine>, Option<BlameLine>)> for BlameRange {
    type Error = CoreError;
    fn try_from((from, to): (Option<BlameLine>, Option<BlameLine>)) -> Result<Self, CoreError> {
        if from.is_none() && to.is_none() {
            return Ok(Self::All);
        }
        let from = from.unwrap_or(BlameLine(1));
        if to.as_ref().is_some_and(|to| from.0 > to.0) {
            return Err(CoreError::InvalidValue {
                field: "BlameWindow",
            });
        }
        Ok(Self::Lines { from, to })
    }
}
#[derive(Deserialize)]
#[serde(try_from = "QueryDto")]
enum Query {
    Log {
        max_count: CommitLimit,
        path: Option<RepositoryPath>,
    },
    Branches {},
    Stashes {},
    Diff {
        staged: bool,
        path: Option<RepositoryPath>,
        commit: Option<Revision>,
    },
    Blame {
        path: RepositoryPath,
        range: BlameRange,
    },
    Status {},
}
impl TryFrom<QueryDto> for Query {
    type Error = CoreError;
    fn try_from(value: QueryDto) -> Result<Self, CoreError> {
        Ok(match value {
            QueryDto::Log { max_count, path } => Self::Log { max_count, path },
            QueryDto::Branches {} => Self::Branches {},
            QueryDto::Stashes {} => Self::Stashes {},
            QueryDto::Diff {
                staged,
                path,
                commit,
            } => Self::Diff {
                staged,
                path,
                commit,
            },
            QueryDto::Blame { path, from, to } => Self::Blame {
                path,
                range: BlameRange::try_from((from, to))?,
            },
        })
    }
}

impl Query {
    fn tool(&self) -> Result<ToolName, CoreError> {
        ToolName::try_from(
            match self {
                Self::Log { .. } => "git_log",
                Self::Branches {} => "git_branches",
                Self::Stashes {} => "git_stashes",
                Self::Diff { .. } => "git_diff",
                Self::Blame { .. } => "git_blame",
                Self::Status {} => "git_status",
            }
            .to_owned(),
        )
    }
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
pub(crate) type GitReadReport = Report<PreparedProfile>;
pub(crate) type RunningGitReadReport = Report<RunningProfile>;
enum Body {
    Text(&'static str),
    Status(StatusReport),
}
pub(crate) struct Report<Profile> {
    output: OutputLimit,
    body: Body,
    profile: Option<Profile>,
    submodules_excluded: bool,
}
impl<Profile> Report<Profile> {
    pub(crate) fn output_limit(&self) -> OutputLimit {
        self.output
    }
    pub(crate) fn coverage(&self) -> &'static str {
        if self.submodules_excluded {
            "main_worktree_without_submodules"
        } else {
            "requested_history_or_file"
        }
    }
    pub(crate) fn text(
        &self,
        stdout: &[u8],
        stderr: &[u8],
        outcome: ToolOutcome,
    ) -> Result<String, CoreError> {
        let stdout = std::str::from_utf8(stdout).map_err(|_| CoreError::InvalidToolOutput)?;
        let stderr = std::str::from_utf8(stderr).map_err(|_| CoreError::InvalidToolOutput)?;
        let mut text = if outcome == ToolOutcome::Ok {
            match &self.body {
                Body::Text(empty) => {
                    let text = stdout.trim();
                    if text.is_empty() {
                        (*empty).to_owned()
                    } else {
                        text.to_owned()
                    }
                }
                Body::Status(report) => report.text(stdout)?,
            }
        } else {
            format!("{}\n{}", stdout.trim(), stderr.trim())
        };
        if self.submodules_excluded {
            text.push_str("\n\n[Safe Git read: submodule working trees are not inspected. Use an explicitly approved Git command for submodule state.]");
        }
        Ok(text)
    }
}
impl Report<PreparedProfile> {
    pub(crate) fn discard(self) -> Result<(), CoreError> {
        self.profile.map_or(Ok(()), PreparedProfile::discard)
    }
    pub(crate) fn issued(self) -> RunningGitReadReport {
        Report {
            output: self.output,
            body: self.body,
            profile: self.profile.map(PreparedProfile::issued),
            submodules_excluded: self.submodules_excluded,
        }
    }
}
impl Report<RunningProfile> {
    pub(crate) fn finish(self, cleanup_complete: bool) -> Result<(), CoreError> {
        self.profile
            .map_or(Ok(()), |profile| profile.finish(cleanup_complete))
    }
}
pub(crate) enum GitReadReply {
    Report(GitReadReport),
    Prepare(Box<GitReadPreparation>),
}
pub(crate) struct GitPrepared {
    pub(crate) command: CommandSpec,
    pub(crate) settings: RunSettings,
    pub(crate) tool: ToolName,
    pub(crate) reply: GitReadReply,
}
struct QueryDeadline(Option<Instant>);
impl QueryDeadline {
    fn new(timeout: Option<Duration>, started: Instant) -> Result<Self, CoreError> {
        Ok(Self(
            timeout
                .map(|timeout| {
                    started
                        .checked_add(timeout)
                        .ok_or(CoreError::ArithmeticOverflow)
                })
                .transpose()?,
        ))
    }
    fn remaining(&self) -> Result<Option<Duration>, CoreError> {
        self.0
            .map(|deadline| {
                deadline
                    .checked_duration_since(Instant::now())
                    .filter(|duration| !duration.is_zero())
                    .ok_or(CoreError::Deadline)
            })
            .transpose()
    }
}
struct ReadPlan {
    repository: Repository,
    query: Query,
    output: OutputLimit,
    deadline: QueryDeadline,
    preflight_output: OutputLimit,
}
impl GitReadInput {
    pub(super) fn status(
        root: PathBuf,
        output_bytes: OutputLimit,
        timeout_ms: ReadTimeout,
    ) -> Self {
        Self {
            root,
            query: Query::Status {},
            output_bytes,
            timeout_ms,
        }
    }
    pub(crate) fn prepare(self, preparation: &Preparation) -> Result<GitPrepared, CoreError> {
        let deadline = QueryDeadline::new(self.timeout_ms.duration(), preparation.started())?;
        deadline.remaining()?;
        let plan = ReadPlan {
            repository: Repository::try_from(self.root)?,
            query: self.query,
            output: self.output_bytes,
            deadline,
            preflight_output: OutputLimit::try_from(65536)?,
        };
        preparation.check()?;
        match &plan.query {
            Query::Diff { .. } | Query::Blame { .. } | Query::Status {} => {
                capture::GitReadPreparation::layout(plan)
            }
            _ => plan.final_query(None),
        }
    }
}
