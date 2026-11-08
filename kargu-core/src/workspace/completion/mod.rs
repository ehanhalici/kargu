//! `@` mention completion candidates: bounded native discovery plus the files
//! the editor is visiting, ranked in Rust. The editor only displays them.

mod rank;

use self::rank::{CandidatePath, MentionQuery, Ranked};
use super::search::{self, FindFilesInput, FindFilesPlan};
use crate::{error::CoreError, security::Workspace};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, path::PathBuf, time::Instant};
use tokio_util::sync::CancellationToken;

/// Most candidates one answer may carry.
const MAX_CANDIDATES: usize = 50;
/// Most visited editor files one request may name.
const MAX_OPEN_FILES: usize = 512;

/// Untrusted editor request, validated once on the I/O worker.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MentionCandidatesInput {
    /// Trusted editor workspace root.
    root: PathBuf,
    /// Text typed after `@`.
    query: String,
    /// Absolute paths of files the editor is visiting; only those inside root count.
    open_files: Vec<PathBuf>,
    /// Shared editor policy: directory basenames excluded at every depth.
    skip_directories: Vec<String>,
    /// Regular files discovery may inspect.
    max_files: usize,
    /// Directories discovery may enter.
    max_directories: usize,
    /// Candidates to return, at most fifty.
    limit: usize,
}

/// Ranked candidates, best first.
#[derive(Serialize)]
pub struct MentionCandidates {
    candidates: Vec<Ranked>,
    /// Discovery hit a limit, so a matching file may be missing.
    truncated: bool,
    /// Short summary required by the shared read envelope.
    text: String,
}

impl MentionCandidatesInput {
    /// Discover, merge and rank on a blocking worker, never on the actor.
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<MentionCandidates, CoreError> {
        let query = MentionQuery::parse(&self.query).ok_or(CoreError::InvalidValue {
            field: "MentionQuery",
        })?;
        if !(1..=MAX_CANDIDATES).contains(&self.limit) || self.open_files.len() > MAX_OPEN_FILES {
            return Err(CoreError::Limit);
        }
        let workspace = Workspace::try_from(self.root.clone())?;
        let found = FindFilesPlan::try_from(FindFilesInput {
            root: self.root,
            path: None,
            pattern: "*".to_owned(),
            skip_directories: self.skip_directories,
            max_files: self.max_files,
            max_directories: self.max_directories,
        })?
        .execute(cancel, deadline)?;
        let visited = self
            .open_files
            .iter()
            .filter_map(|path| search::displayable(&workspace, path))
            .filter_map(|path| path.to_str().map(str::to_owned));
        let paths: BTreeSet<String> = found.files.into_iter().chain(visited).collect();
        let candidates = best(&query, paths, self.limit);
        let text = format!("{} mention candidate(s)", candidates.len());
        Ok(MentionCandidates {
            candidates,
            truncated: found.truncated,
            text,
        })
    }
}

/// The `limit` best-ranked paths, ties broken by path.
fn best(query: &MentionQuery, paths: BTreeSet<String>, limit: usize) -> Vec<Ranked> {
    let mut ranked: Vec<Ranked> = paths
        .into_iter()
        .filter_map(|path| query.rank(CandidatePath::new(path)))
        .collect();
    ranked.sort();
    ranked.truncate(limit);
    ranked
}
