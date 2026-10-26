//! Explicit editor file grants, not model/workspace tool arguments.

use crate::error::CoreError;
use serde::Deserialize;
use std::{
    path::{Component, PathBuf},
    time::Duration,
};

#[derive(Deserialize)]
#[serde(try_from = "String")]
pub(crate) struct ConfigurationPath(pub(super) PathBuf);
impl ConfigurationPath {
    pub(crate) fn as_path(&self) -> &std::path::Path {
        &self.0
    }
}
impl TryFrom<String> for ConfigurationPath {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let path = PathBuf::from(&value);
        if value.len() > 4096
            || value.chars().any(char::is_control)
            || !path.is_absolute()
            || path
                .components()
                .any(|part| matches!(part, Component::ParentDir))
        {
            return Err(CoreError::InvalidValue {
                field: "configuration_path",
            });
        }
        Ok(Self(path))
    }
}

#[derive(Deserialize)]
#[serde(try_from = "Vec<ConfigurationPath>")]
pub(super) struct CandidatePaths(pub(super) Vec<ConfigurationPath>);
impl TryFrom<Vec<ConfigurationPath>> for CandidatePaths {
    type Error = CoreError;
    fn try_from(paths: Vec<ConfigurationPath>) -> Result<Self, Self::Error> {
        if paths.is_empty() || paths.len() > 8 {
            return Err(CoreError::InvalidValue {
                field: "configuration_paths",
            });
        }
        Ok(Self(paths))
    }
}

#[derive(Deserialize)]
#[serde(try_from = "u64")]
pub(crate) struct ReadTimeout(Duration);
impl Default for ReadTimeout {
    fn default() -> Self {
        Self(Duration::from_secs(5))
    }
}
impl TryFrom<u64> for ReadTimeout {
    type Error = CoreError;
    fn try_from(millis: u64) -> Result<Self, Self::Error> {
        if !(1..=5000).contains(&millis) {
            return Err(CoreError::InvalidValue {
                field: "configuration_timeout",
            });
        }
        Ok(Self(Duration::from_millis(millis)))
    }
}
impl ReadTimeout {
    pub(crate) fn duration(&self) -> Duration {
        self.0
    }
}
