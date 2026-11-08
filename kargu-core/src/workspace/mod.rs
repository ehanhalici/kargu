//! Closed native read-operation boundary shared by host admission and IO workers.

pub(crate) mod command;
pub mod completion;
pub mod file;
pub mod git;
pub(crate) mod gitignore;
pub mod grep;
pub mod listing;
pub(crate) mod probe;
pub mod search;
pub(crate) mod skills;
pub(crate) mod webfetch;

use self::search::{FindFilesInput, FindFilesPlan, FindFilesResult};
use crate::error::CoreError;
use serde::Serialize;
use std::time::Instant;
use tokio_util::sync::CancellationToken;

pub(crate) enum WorkspaceRead {
    FindFiles(FindFilesInput),
    ReadFile(file::ReadFileInput),
    Skills(skills::SkillInput),
    Webfetch(webfetch::FetchInput),
    Probe(probe::ProbeInput),
    MentionCandidates(completion::MentionCandidatesInput),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum ReadResult {
    FindFiles(FindFilesResult),
    File(file::FileExcerpt),
    Skills(skills::SkillResult),
    Webfetch(webfetch::FetchResult),
    Probe(probe::ProbeResult),
    MentionCandidates(completion::MentionCandidates),
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
            Self::Probe(input) => input.execute(cancel, deadline).map(ReadResult::Probe),
            Self::MentionCandidates(input) => input
                .execute(cancel, deadline)
                .map(ReadResult::MentionCandidates),
            Self::Webfetch(input) => input.execute(cancel, deadline).map(ReadResult::Webfetch),
            Self::Skills(input) => input.execute(cancel, deadline).map(ReadResult::Skills),
            Self::ReadFile(input) => input.execute(cancel, deadline).map(ReadResult::File),
            Self::FindFiles(input) => FindFilesPlan::try_from(input)?
                .execute(cancel, deadline)
                .map(ReadResult::FindFiles),
        }
    }
}

impl ReadResult {
    pub(crate) fn into_tool_output(
        self,
    ) -> Result<(crate::application::ToolOutcome, String), CoreError> {
        use crate::application::ToolOutcome;
        match self {
            Self::FindFiles(result) => Ok((ToolOutcome::Ok, result.text)),
            Self::File(result) => Ok((ToolOutcome::Ok, result.text)),
            Self::Skills(result) => Ok(result.into_tool_output()),
            Self::Webfetch(result) => Ok((result.outcome(), result.into_text())),
            Self::Probe(_) | Self::MentionCandidates(_) => Err(CoreError::InvalidToolOutput),
        }
    }
}
