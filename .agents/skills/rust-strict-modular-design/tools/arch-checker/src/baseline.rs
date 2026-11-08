//! Ratchet baselines: known violations that may only disappear.
//!
//! A baseline is a sorted list of finding keys (see [`Finding::key`]).  The
//! check is exact in both directions: a finding missing from the baseline is a
//! new violation, and a baseline entry no finding matches is stale and must be
//! deleted, so the file always tells the truth and can only shrink by fixing.
//! Pure: callers read and write the files.

use crate::finding::Finding;
use std::collections::BTreeMap;

/// How the current findings differ from a baseline.
pub struct Comparison<'a> {
    new: Vec<&'a Finding>,
    stale: Vec<String>,
}

impl Comparison<'_> {
    /// Findings the baseline does not cover.
    pub fn new_findings(&self) -> &[&Finding] {
        &self.new
    }

    /// Baseline entries that no longer match any finding.
    pub fn stale(&self) -> &[String] {
        &self.stale
    }
}

/// One rule whose violation count grew against the previous baseline.
pub struct Growth {
    rule: String,
    before: usize,
    now: usize,
}

impl std::fmt::Display for Growth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "[{}] baseline grew from {} to {}; fix the new violations instead",
            self.rule, self.before, self.now
        )
    }
}

/// Keys of a baseline file: non-empty lines that are not `#` comments.
pub fn parse(text: &str) -> Vec<String> {
    text.lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

/// The baseline text that exactly covers `findings`.
pub fn render(findings: &[Finding]) -> String {
    let mut keys: Vec<String> = findings.iter().map(Finding::key).collect();
    keys.sort();
    let mut text = String::from(
        "# arch-checker ratchet baseline: known violations that may only be removed.\n\
         # Regenerate with `arch-checker --write-baseline arch-checker.baseline .`\n",
    );
    for key in keys {
        text.push_str(&key);
        text.push('\n');
    }
    text
}

/// Compare findings with a baseline as multisets.
pub fn compare<'a>(findings: &'a [Finding], baseline: &[String]) -> Comparison<'a> {
    let mut remaining = counts(baseline.iter().map(String::as_str));
    let mut new = Vec::new();
    for finding in findings {
        let key = finding.key();
        match remaining.get_mut(key.as_str()) {
            Some(count) if *count > 0 => *count = count.saturating_sub(1),
            _ => new.push(finding),
        }
    }
    let stale = remaining
        .into_iter()
        .flat_map(|(key, count)| std::iter::repeat_n(key.to_owned(), count))
        .collect();
    Comparison { new, stale }
}

/// Rules whose count in `current` exceeds their count in `previous`.
///
/// Counting per rule (not per key) lets code move or be renamed while still
/// forbidding any net growth of a rule's violations.
pub fn growth(current: &[String], previous: &[String]) -> Vec<Growth> {
    let before = counts(previous.iter().map(|key| rule_of(key)));
    counts(current.iter().map(|key| rule_of(key)))
        .into_iter()
        .filter_map(|(rule, now)| {
            let was = before.get(rule).copied().unwrap_or_default();
            (now > was).then(|| Growth {
                rule: rule.to_owned(),
                before: was,
                now,
            })
        })
        .collect()
}

fn rule_of(key: &str) -> &str {
    key.split('\t').next().unwrap_or_default()
}

fn counts<'a>(keys: impl Iterator<Item = &'a str>) -> BTreeMap<&'a str, usize> {
    let mut map = BTreeMap::new();
    for key in keys {
        let count: &mut usize = map.entry(key).or_default();
        *count = count.saturating_add(1);
    }
    map
}
