//! Validated write intents; arbitrary argv, revision expressions and pop/drop are absent.
use super::scope;
use crate::{domain::ToolName, error::CoreError};
use serde::{Deserialize, Serialize};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};
#[derive(Deserialize, Serialize)]
#[serde(try_from = "String")]
pub(super) struct Message(pub(super) String);
impl TryFrom<String> for Message {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.trim().is_empty() || value.len() > 32768 || value.contains('\0') {
            return Err(CoreError::InvalidValue {
                field: "GitMessage",
            });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize, Serialize)]
#[serde(try_from = "String")]
pub(super) struct Branch(pub(super) String);
impl TryFrom<String> for Branch {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty()
            || value.len() > 1024
            || value.starts_with(['-', '/', '.'])
            || value.ends_with(['.', '/'])
            || value.contains("..")
            || value.contains("@{")
            || value.contains("//")
            || value
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || "~^:?*[\\".contains(c))
            || value
                .split('/')
                .any(|s| s.starts_with('.') || s.ends_with(".lock"))
        {
            return Err(CoreError::InvalidValue { field: "GitBranch" });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize, Serialize)]
#[serde(try_from = "Vec<PathBuf>")]
pub(super) struct Paths(pub(super) Vec<PathBuf>);
impl TryFrom<Vec<PathBuf>> for Paths {
    type Error = CoreError;
    fn try_from(value: Vec<PathBuf>) -> Result<Self, CoreError> {
        if value.is_empty() || value.len() > 128 {
            return Err(CoreError::Limit);
        }
        for path in &value {
            crate::workspace::command::validate_path(path)?;
            if path.as_os_str().is_empty() || path.as_os_str().as_encoded_bytes().contains(&0) {
                return Err(CoreError::Rejected);
            }
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize, Serialize)]
#[serde(try_from = "String")]
pub(super) struct Stash(pub(super) String);
impl TryFrom<String> for Stash {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let index = value
            .strip_prefix("stash@{")
            .and_then(|s| s.strip_suffix('}'));
        if !index.is_some_and(|s| {
            !s.is_empty() && s.len() <= 10 && s.bytes().all(|b| b.is_ascii_digit())
        }) {
            return Err(CoreError::InvalidValue { field: "GitStash" });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum Mutation {
    Stage {
        paths: Paths,
    },
    Unstage {
        paths: Paths,
    },
    Commit {
        message: Message,
        #[serde(default)]
        all: bool,
    },
    BranchCreate {
        name: Branch,
    },
    BranchSwitch {
        name: Branch,
    },
    BranchDelete {
        name: Branch,
    },
    StashPush {
        message: Option<Message>,
    },
    StashApply {
        stash: Stash,
    },
}
impl Mutation {
    pub(super) fn tool(&self) -> Result<ToolName, CoreError> {
        ToolName::try_from(
            match self {
                Self::Stage { .. } => "git_stage",
                Self::Unstage { .. } => "git_unstage",
                Self::Commit { .. } => "git_commit",
                Self::BranchCreate { .. }
                | Self::BranchSwitch { .. }
                | Self::BranchDelete { .. } => "git_branch",
                _ => "git_stash",
            }
            .to_owned(),
        )
    }
    pub(super) fn resolve(&self) -> String {
        match self {
            Self::StashApply { stash } => format!("{}^{{commit}}", stash.0),
            Self::BranchSwitch { name } => format!("refs/heads/{}", name.0),
            _ => "HEAD".into(),
        }
    }
    pub(super) fn arguments(
        &self,
        object: Option<&str>,
        root: &Path,
    ) -> Result<Vec<OsString>, CoreError> {
        let argv: Vec<String> = match self {
            Self::Stage { .. } => vec!["add".into(), "--".into()],
            Self::Unstage { .. } => match object {
                Some(oid) => vec!["reset".into(), oid.into(), "--".into()],
                None => vec![
                    "rm".into(),
                    "--cached".into(),
                    "-r".into(),
                    "--ignore-unmatch".into(),
                    "--".into(),
                ],
            },
            Self::Commit { message, all } => {
                let mut a = vec!["commit".into(), "-m".into(), message.0.clone()];
                if *all {
                    a.push("-a".into());
                }
                a
            }
            Self::BranchCreate { name } => {
                let mut a = vec!["checkout".into(), "-b".into(), name.0.clone()];
                if let Some(oid) = object {
                    a.push(oid.into());
                }
                a
            }
            Self::BranchSwitch { name } => {
                if object.is_none() {
                    return Err(CoreError::Rejected);
                }
                vec!["checkout".into(), name.0.clone()]
            }
            Self::BranchDelete { name } => {
                vec!["branch".into(), "-d".into(), "--".into(), name.0.clone()]
            }
            Self::StashPush { message } => {
                let mut a = vec!["stash".into(), "push".into()];
                if let Some(m) = message {
                    a.extend(["-m".into(), m.0.clone()]);
                }
                a
            }
            Self::StashApply { .. } => vec![
                "stash".into(),
                "apply".into(),
                object.ok_or(CoreError::Rejected)?.into(),
            ],
        };
        let mut argv: Vec<OsString> = argv.into_iter().map(OsString::from).collect();
        if let Self::Stage { paths } | Self::Unstage { paths } = self {
            for path in &paths.0 {
                argv.push(scope::relative(root, path)?.into());
            }
        }
        Ok(argv)
    }
}
