//! Fixed-argv GNU ls adapter. Listing and formatting belong to ls, not Rust.

use crate::{
    application::{Mode, RunSettings},
    constants::{limits, timeouts},
    domain::{ConfigRevision, PolicyRevision, ToolCallLimit},
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Component, Path, PathBuf},
};

/// Client-captured listing configuration, not general-purpose command arguments.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListFilesInput {
    /// Trusted editor workspace root.
    pub root: PathBuf,
    /// Directory relative to root, or an absolute contained directory.
    pub path: Option<PathBuf>,
    /// Literal basenames excluded through ls --ignore patterns.
    pub skip_directories: Vec<String>,
}

impl ListFilesInput {
    pub(crate) fn prepare(self) -> Result<(CommandSpec, RunSettings), CoreError> {
        let path = self.path.as_deref().unwrap_or(Path::new("."));
        for input in [&self.root, path] {
            if input.as_os_str().len() > limits::SEARCH_PATH_BYTES
                || input.components().any(|c| c == Component::ParentDir)
            {
                return Err(CoreError::Rejected);
            }
        }
        if !self.root.is_absolute() {
            return Err(CoreError::Rejected);
        }
        let arguments = arguments(self.skip_directories)?;
        let workspace = Workspace::try_from(self.root)?;
        let target = workspace.path().join(path).canonicalize()?;
        if !target.starts_with(workspace.path()) {
            return Err(CoreError::Rejected);
        }
        let command = CommandSpec::directory_listing(CommandInput {
            program: executable()?,
            arguments,
            working_directory: target,
            timeout: Some(timeouts::WORKSPACE_READ),
            environment: CommandEnvironment::try_from(BTreeMap::from([(
                "LC_ALL".into(),
                "C".into(),
            )]))?,
        })?;
        let settings = RunSettings::new(
            Mode::Ask,
            workspace,
            ToolCallLimit::default(),
            timeouts::WORKSPACE_READ,
            ConfigRevision::ZERO,
            PolicyRevision::ZERO,
        )?;
        Ok((command, settings))
    }
}

fn executable() -> Result<PathBuf, CoreError> {
    let paths = std::env::var_os("PATH").ok_or(CoreError::Unavailable)?;
    std::env::split_paths(&paths)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join("ls"))
        .find(|path| path.is_file())
        .ok_or(CoreError::Unavailable)
}

fn arguments(exclusions: Vec<String>) -> Result<Vec<OsString>, CoreError> {
    if exclusions.len() > 64 {
        return Err(CoreError::Limit);
    }
    let mut args: Vec<OsString> = [
        "-lAh",
        "--numeric-uid-gid",
        "--color=never",
        "--quoting-style=shell-escape",
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    for name in exclusions {
        if name.is_empty()
            || name.len() > 256
            || matches!(name.as_str(), "." | "..")
            || name.contains(['/', '\0'])
        {
            return Err(CoreError::InvalidValue {
                field: "ListingExclusion",
            });
        }
        // GNU --ignore accepts globs; escape literals without inspecting any entries.
        let literal: String = name
            .chars()
            .flat_map(|c| {
                if matches!(c, '*' | '?' | '[' | ']' | '\\') {
                    vec!['\\', c]
                } else {
                    vec![c]
                }
            })
            .collect();
        args.push(format!("--ignore={literal}").into());
    }
    args.extend([OsString::from("--"), OsString::from(".")]);
    Ok(args)
}
