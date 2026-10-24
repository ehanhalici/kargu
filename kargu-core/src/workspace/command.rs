//! Shared host executable lookup and literal exclusion arguments, not traversal.

use crate::error::CoreError;
use std::{os::unix::fs::PermissionsExt, path::PathBuf};

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
