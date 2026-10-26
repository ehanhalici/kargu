//! Shared host executable lookup and literal exclusion arguments, not traversal.

use crate::error::CoreError;
use crate::{constants::timeouts, domain::ExecutionTimeout};
use serde::Deserialize;
use std::time::Duration;
use std::{os::unix::fs::PermissionsExt, path::PathBuf};

/// Missing uses the bounded read default; explicit null disables the deadline.
#[derive(Default, Deserialize)]
#[serde(try_from = "Option<u64>")]
pub(super) struct ReadTimeout(Option<ExecutionTimeout>);
impl TryFrom<Option<u64>> for ReadTimeout {
    type Error = CoreError;
    fn try_from(value: Option<u64>) -> Result<Self, CoreError> {
        if value.is_some_and(|value| value > 86_400_000) {
            return Err(CoreError::InvalidValue {
                field: "ReadTimeout",
            });
        }
        Ok(Self(Some(ExecutionTimeout::try_from(
            value.map(Duration::from_millis),
        )?)))
    }
}
impl ReadTimeout {
    pub(super) fn duration(self) -> Option<Duration> {
        self.0
            .map_or(Some(timeouts::WORKSPACE_READ), |timeout| timeout.duration())
    }
}

pub(super) fn executable(name: &str) -> Result<PathBuf, CoreError> {
    let paths = std::env::var_os("PATH").ok_or(CoreError::Unavailable)?;
    std::env::split_paths(&paths)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join(name))
        .find(|path| {
            path.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .ok_or(CoreError::Unavailable)
}

pub(super) fn exclusions(names: Vec<String>) -> Result<Vec<String>, CoreError> {
    if names.len() > 64 {
        return Err(CoreError::Limit);
    }
    names
        .into_iter()
        .map(|name| {
            if name.is_empty()
                || name.len() > 256
                || matches!(name.as_str(), "." | "..")
                || name.contains(['/', '\0', '\n', '\r'])
            {
                return Err(CoreError::InvalidValue {
                    field: "SearchExclusion",
                });
            }
            // Both GNU ignore and rg glob options interpret wildcard metacharacters.
            Ok(name
                .chars()
                .flat_map(|c| {
                    if matches!(c, '*' | '?' | '[' | ']' | '\\' | '{' | '}') {
                        vec!['\\', c]
                    } else {
                        vec![c]
                    }
                })
                .collect())
        })
        .collect()
}

pub(crate) fn validate_path(path: &std::path::Path) -> Result<(), CoreError> {
    if path.as_os_str().len() > crate::constants::limits::SEARCH_PATH_BYTES
        || path
            .components()
            .any(|component| component == std::path::Component::ParentDir)
    {
        return Err(CoreError::Rejected);
    }
    Ok(())
}
