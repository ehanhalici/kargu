//! Git CLI adapters. Repository mechanics remain Git's responsibility.

mod query;
mod repository;
mod status;
pub use query::GitReadInput;
pub(crate) use query::GitReadReport;
pub(crate) use status::StatusReport;

use super::command::ReadTimeout;
use crate::{
    application::RunSettings, domain::OutputLimit, error::CoreError, security::CommandSpec,
};
use repository::Repository;
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
    pub(crate) fn prepare(self) -> Result<(CommandSpec, RunSettings, StatusReport), CoreError> {
        let repository = Repository::try_from(self.root)?;
        let timeout = self.timeout_ms.duration();
        let command = repository.command(
            vec![
                "status".into(),
                "--porcelain=v1".into(),
                "-b".into(),
                "-z".into(),
            ],
            timeout,
            self.output_bytes,
        )?;
        let report =
            StatusReport::new(repository.workspace.path().to_path_buf(), self.output_bytes);
        Ok((command, repository.settings(timeout)?, report))
    }
}
