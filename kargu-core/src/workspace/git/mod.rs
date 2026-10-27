//! Git CLI adapters. Repository mechanics remain Git's responsibility.

pub(crate) mod mutation;
mod profile;
mod query;
mod repository;
mod status;
pub use query::GitReadInput;
pub(crate) use query::GitReadReport;
pub(crate) use query::{GitPrepared, GitReadPreparation, GitReadReply, RunningGitReadReport};

use super::command::ReadTimeout;
use crate::{domain::OutputLimit, error::CoreError};
use serde::Deserialize;
use std::path::PathBuf;

/// Repository-root scoped fixed-argv status, not arbitrary Git arguments.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitStatusInput {
    root: PathBuf,
    #[serde(default)]
    output_bytes: OutputLimit,
    #[serde(default)]
    timeout_ms: ReadTimeout,
}
impl GitStatusInput {
    pub(crate) fn prepare(
        self,
        preparation: &super::command::Preparation,
    ) -> Result<GitPrepared, CoreError> {
        GitReadInput::status(self.root, self.output_bytes, self.timeout_ms).prepare(preparation)
    }
}
