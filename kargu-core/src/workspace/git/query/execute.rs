//! Final fixed-argv query construction after owned preflight capture.

use super::{
    BlameRange, Body, CapturedProfile, GitPrepared, GitReadReply, Query, ReadPlan, Report,
    StatusReport,
};
use crate::error::CoreError;
use std::ffi::OsString;

impl ReadPlan {
    pub(super) fn final_query(
        self,
        profile: Option<CapturedProfile>,
    ) -> Result<GitPrepared, CoreError> {
        let tool = self.query.tool()?;
        let (body, mut arguments, path, submodules_excluded) = match self.query {
            Query::Log { max_count, path } => (
                Body::Text("(no commits found)"),
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
                false,
            ),
            Query::Branches {} => (
                Body::Text(""),
                vec!["branch".into(), "-a".into(), "--no-color".into()],
                None,
                false,
            ),
            Query::Stashes {} => (
                Body::Text("(no stash entries)"),
                vec![
                    "stash".into(),
                    "list".into(),
                    "--no-color".into(),
                    "--no-show-signature".into(),
                    "--no-patch".into(),
                ],
                None,
                false,
            ),
            Query::Diff {
                staged,
                path,
                commit,
            } => {
                let mut arguments: Vec<OsString> = vec![
                    "diff".into(),
                    "--no-color".into(),
                    "--no-ext-diff".into(),
                    "--no-textconv".into(),
                    "--ignore-submodules=all".into(),
                    "--submodule=short".into(),
                ];
                if staged {
                    arguments.push("--cached".into());
                }
                if let Some(commit) = commit {
                    arguments.push(commit.0.into());
                }
                (Body::Text("(no diff output)"), arguments, path, true)
            }
            Query::Blame { path, range } => {
                let mut arguments: Vec<OsString> = vec![
                    "blame".into(),
                    "--date=short".into(),
                    "--no-textconv".into(),
                ];
                if let BlameRange::Lines { from, to } = range {
                    arguments.push(
                        format!(
                            "-L{},{}",
                            from.0,
                            to.map_or_else(String::new, |to| to.0.to_string())
                        )
                        .into(),
                    );
                }
                (Body::Text(""), arguments, Some(path), false)
            }
            Query::Status {} => (
                Body::Status(StatusReport::new(
                    self.repository.workspace.path().to_owned(),
                )),
                vec![
                    "status".into(),
                    "--porcelain=v1".into(),
                    "-b".into(),
                    "-z".into(),
                    "--ignore-submodules=all".into(),
                ],
                None,
                true,
            ),
        };
        let target = path
            .map(|path| path.capture(&self.repository))
            .transpose()?;
        arguments.push("--".into());
        if let Some((relative, _)) = &target {
            arguments.push(relative.clone());
        }
        let timeout = self.deadline.remaining()?;
        let mut command = match &profile {
            Some(profile) => {
                self.repository
                    .isolated_command(arguments, timeout, self.output, profile)?
            }
            None => self.repository.command(arguments, timeout, self.output)?,
        };
        if let Some((_, target)) = target {
            command = command.with_read_target(target)?;
        }
        Ok(GitPrepared {
            command,
            settings: self.repository.settings(timeout)?,
            tool,
            reply: GitReadReply::Report(Report {
                output: self.output,
                body,
                profile: profile.map(CapturedProfile::prepared),
                submodules_excluded,
            }),
        })
    }
}
