//! Fuzzy ranking of `@` mention completion paths. Pure: no I/O.
//!
//! Lower ranks are better: an exact basename beats a basename prefix, a
//! basename substring, a path prefix, a path substring, then an in-order
//! basename subsequence and finally an in-order path subsequence (the
//! subsequences ranked by how tightly they match).

use serde::Serialize;

/// Longest accepted query, in characters.
const MAX_QUERY_CHARS: usize = 256;

/// A bounded, case-folded completion query (without the leading `@`).
pub(crate) struct MentionQuery(Vec<char>);

/// A workspace-relative candidate path as shown to the user.
pub(crate) struct CandidatePath(String);

/// One ranked candidate: its path and the character ranges the query matched.
#[derive(Serialize)]
pub(crate) struct Ranked {
    #[serde(skip)]
    rank: usize,
    path: String,
    /// Half-open `[start, end)` character ranges inside `path`.
    #[serde(rename = "match")]
    chunks: Vec<(usize, usize)>,
}

impl MentionQuery {
    /// Fold `raw` once; `None` when it exceeds the query bound.
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        (raw.chars().count() <= MAX_QUERY_CHARS).then(|| Self(fold(raw)))
    }

    /// Rank `path`, or `None` when the query does not match it at all.
    pub(crate) fn rank(&self, path: CandidatePath) -> Option<Ranked> {
        let full = fold(&path.0);
        let base_start = basename_start(&path.0);
        let base = full.get(base_start..).unwrap_or_default();
        let rank = self.score(&full, base)?;
        let chunks = self.chunks(&full, base_start);
        Some(Ranked {
            rank,
            path: path.0,
            chunks,
        })
    }

    fn score(&self, full: &[char], base: &[char]) -> Option<usize> {
        let query = self.0.as_slice();
        if query.is_empty() {
            return Some(50);
        }
        let direct = [
            base == query,
            base.starts_with(query),
            contains(base, query),
            full.starts_with(query),
            contains(full, query),
        ];
        if let Some(rank) = direct.iter().position(|hit| *hit) {
            return Some(rank);
        }
        subsequence(query, base)
            .map(|indices| 10_usize.saturating_add(slack(&indices, query.len())))
            .or_else(|| {
                subsequence(query, full)
                    .map(|indices| 20_usize.saturating_add(slack(&indices, query.len())))
            })
    }

    /// Highlight inside the basename when it matches there, else in the path.
    fn chunks(&self, full: &[char], base_start: usize) -> Vec<(usize, usize)> {
        let base = full.get(base_start..).unwrap_or_default();
        let shifted = subsequence(&self.0, base).map(|indices| {
            indices
                .into_iter()
                .map(|index| index.saturating_add(base_start))
                .collect::<Vec<_>>()
        });
        shifted
            .or_else(|| subsequence(&self.0, full))
            .map(|indices| runs(&indices))
            .unwrap_or_default()
    }
}

impl CandidatePath {
    /// Wrap a relative path already validated by the discovery worker.
    pub(crate) fn new(path: String) -> Self {
        Self(path)
    }
}

/// Best rank first, then the path for a stable order.
impl Ord for Ranked {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.rank, &self.path).cmp(&(other.rank, &other.path))
    }
}
impl PartialOrd for Ranked {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl PartialEq for Ranked {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other).is_eq()
    }
}
impl Eq for Ranked {}

/// Character-wise case folding that keeps one character per input character,
/// so match ranges stay valid indices into the original path.
fn fold(text: &str) -> Vec<char> {
    text.chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect()
}

/// Character index where the last path component starts.
fn basename_start(path: &str) -> usize {
    path.rfind('/').map_or(0, |slash| {
        path.get(..slash)
            .map_or(0, |head| head.chars().count().saturating_add(1))
    })
}

fn contains(haystack: &[char], needle: &[char]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// Greedy in-order positions of every `query` character in `text`.
fn subsequence(query: &[char], text: &[char]) -> Option<Vec<usize>> {
    if query.is_empty() {
        return None;
    }
    let mut wanted = query.iter().peekable();
    let mut indices = Vec::with_capacity(query.len());
    for (index, character) in text.iter().enumerate() {
        if wanted.next_if(|next| *next == character).is_some() {
            indices.push(index);
        }
    }
    wanted.peek().is_none().then_some(indices)
}

/// Characters skipped between the first and last matched position.
fn slack(indices: &[usize], query_len: usize) -> usize {
    match (indices.first(), indices.last()) {
        (Some(first), Some(last)) => last
            .saturating_sub(*first)
            .saturating_add(1)
            .saturating_sub(query_len),
        _ => 0,
    }
}

/// Merge consecutive positions into half-open ranges.
fn runs(indices: &[usize]) -> Vec<(usize, usize)> {
    let mut chunks: Vec<(usize, usize)> = Vec::new();
    for index in indices {
        match chunks.last_mut() {
            Some(last) if last.1 == *index => last.1 = index.saturating_add(1),
            _ => chunks.push((*index, index.saturating_add(1))),
        }
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::{CandidatePath, MentionQuery};

    fn rank(query: &str, path: &str) -> Option<(usize, Vec<(usize, usize)>)> {
        let ranked = MentionQuery::parse(query)?.rank(CandidatePath::new(path.to_owned()))?;
        Some((ranked.rank, ranked.chunks))
    }

    #[test]
    fn ranks_follow_match_quality() {
        assert_eq!(rank("main.rs", "src/main.rs").map(|r| r.0), Some(0));
        assert_eq!(rank("mai", "src/main.rs").map(|r| r.0), Some(1));
        assert_eq!(rank("ain", "src/main.rs").map(|r| r.0), Some(2));
        assert_eq!(rank("src/m", "src/main.rs").map(|r| r.0), Some(3));
        assert_eq!(rank("c/ma", "src/main.rs").map(|r| r.0), Some(4));
        assert_eq!(rank("mrs", "src/main.rs").map(|r| r.0), Some(14));
        assert_eq!(rank("smn", "src/main.rs").map(|r| r.0), Some(25));
        assert_eq!(rank("zz", "src/main.rs"), None);
        assert_eq!(rank("", "src/main.rs").map(|r| r.0), Some(50));
    }

    #[test]
    fn chunks_prefer_the_basename_and_count_characters() {
        assert_eq!(rank("MaI", "src/main.rs").map(|r| r.1), Some(vec![(4, 7)]));
        assert_eq!(
            rank("sm", "src/main.rs").map(|r| r.1),
            Some(vec![(0, 1), (4, 5)])
        );
        assert_eq!(rank("ğü", "dir/ağüs.txt").map(|r| r.1), Some(vec![(5, 7)]));
        assert_eq!(rank("", "src/main.rs").map(|r| r.1), Some(vec![]));
    }

    #[test]
    fn oversized_queries_are_rejected() {
        assert!(MentionQuery::parse(&"a".repeat(257)).is_none());
        assert!(MentionQuery::parse(&"a".repeat(256)).is_some());
    }
}
