//! Explicit editor file grants, not model/workspace tool arguments.

use crate::error::CoreError;
use serde::Deserialize;
use std::{path::PathBuf, time::Duration};

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
        if !path.is_absolute() || crate::domain::check_path(&path).is_err() {
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

#[derive(Clone, Copy, Deserialize)]
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
