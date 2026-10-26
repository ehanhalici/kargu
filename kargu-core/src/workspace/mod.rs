//! Closed native read-operation boundary shared by host admission and IO workers.

pub(crate) mod command;
pub mod file;
pub mod git;
pub mod grep;
pub mod listing;
pub mod search;
pub(crate) mod skills;

use self::search::{FindFilesInput, FindFilesPlan, FindFilesResult};
use crate::error::CoreError;
use serde::Serialize;
use std::time::Instant;
use tokio_util::sync::CancellationToken;

pub(crate) enum WorkspaceRead {
    FindFiles(FindFilesInput),
    ReadFile(file::ReadFileInput),
    Skills(skills::SkillInput),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum ReadResult {
    FindFiles(FindFilesResult),
    File(file::FileExcerpt),
    Skills(skills::SkillResult),
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
            Self::Skills(input) => input.execute(cancel, deadline).map(ReadResult::Skills),
            Self::ReadFile(input) => input.execute(cancel, deadline).map(ReadResult::File),
            Self::FindFiles(input) => FindFilesPlan::try_from(input)?
                .execute(cancel, deadline)
                .map(ReadResult::FindFiles),
        }
    }
}
