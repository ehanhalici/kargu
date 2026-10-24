//! Closed native read-operation boundary shared by host admission and IO workers.

mod command;
pub mod grep;
pub mod listing;
pub mod search;

use self::search::{FindFilesInput, FindFilesPlan, FindFilesResult};
use crate::error::CoreError;
use serde::Serialize;
use std::time::Instant;
use tokio_util::sync::CancellationToken;

pub(crate) enum WorkspaceRead {
    FindFiles(FindFilesInput),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum ReadResult {
    FindFiles(FindFilesResult),
}

impl WorkspaceRead {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ReadResult, CoreError> {
        if cancel.is_cancelled() {
            return Err(CoreError::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(CoreError::Deadline);
        }
        match self {
            Self::FindFiles(input) => FindFilesPlan::try_from(input)?
                .execute(cancel, deadline)
                .map(ReadResult::FindFiles),
        }
    }
}
