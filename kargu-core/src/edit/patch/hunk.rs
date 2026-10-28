//! Complete hunk framing. Matching and applying remain the installed Git's job.
use crate::edit::{
    EditError,
    types::{EditText, NewLine, NewLineCount, OldLine, OldLineCount},
};
use std::{iter::Peekable, str::SplitTerminator};
use zeroize::Zeroizing;

const NO_NEWLINE: &str = "\\ No newline at end of file";
/// Validated complete hunk. Incomplete drafts never cross this boundary.
pub struct Hunk {
    header: String,
    body: Vec<BodyLine>,
    old_start: OldLine,
    new_start: NewLine,
    old_count: OldLineCount,
    new_count: NewLineCount,
}
enum BodyLine {
    Context(Zeroizing<String>),
    Removed(Zeroizing<String>),
    Added(Zeroizing<String>),
    NoNewline,
}
struct Draft {
    hunk: Hunk,
    old_left: OldLineCount,
    new_left: NewLineCount,
}
impl Draft {
    fn line(&mut self, line: &str) -> Result<(), EditError> {
        let (prefix, text) = line.split_at_checked(1).ok_or(EditError::InvalidPatch)?;
        let old = self.old_left.get();
        let new = self.new_left.get();
        let (old, new, body) = match prefix {
            " " => (
                old.checked_sub(1),
                new.checked_sub(1),
                BodyLine::Context(Zeroizing::new(text.to_owned())),
            ),
            "-" => (
                old.checked_sub(1),
                Some(new),
                BodyLine::Removed(Zeroizing::new(text.to_owned())),
            ),
            "+" => (
                Some(old),
                new.checked_sub(1),
                BodyLine::Added(Zeroizing::new(text.to_owned())),
            ),
            "\\" if line == NO_NEWLINE
                && !self.hunk.body.is_empty()
                && !matches!(self.hunk.body.last(), Some(BodyLine::NoNewline)) =>
            {
                (Some(old), Some(new), BodyLine::NoNewline)
            }
            _ => return Err(EditError::InvalidPatch),
        };
        self.old_left = OldLineCount::try_from(old.ok_or(EditError::InvalidPatch)?)?;
        self.new_left = NewLineCount::try_from(new.ok_or(EditError::InvalidPatch)?)?;
        self.hunk.body.push(body);
        Ok(())
    }
    fn finish(self) -> Result<Hunk, EditError> {
        if self.old_left.get() != 0 || self.new_left.get() != 0 {
            return Err(EditError::InvalidPatch);
        }
        Ok(self.hunk)
    }
}
fn range(text: &str) -> Result<(usize, usize), EditError> {
    let (start, count) = text.split_once(',').map_or((text, "1"), |(s, c)| (s, c));
    if start.is_empty()
        || count.is_empty()
        || !start
            .bytes()
            .chain(count.bytes())
            .all(|b| b.is_ascii_digit())
    {
        return Err(EditError::InvalidPatch);
    }
    let start = start
        .parse::<usize>()
        .map_err(|_| EditError::InvalidPatch)?;
    let count = count
        .parse::<usize>()
        .map_err(|_| EditError::InvalidPatch)?;
    if count > 0 && start == 0 {
        return Err(EditError::InvalidPatch);
    }
    start.checked_add(count).ok_or(EditError::Limit)?;
    Ok((start, count))
}
impl Hunk {
    pub(super) fn parse(
        header: &str,
        lines: &mut Peekable<SplitTerminator<'_, char>>,
    ) -> Result<Self, EditError> {
        let header_ranges = header
            .strip_prefix("@@ -")
            .and_then(|s| s.split_once(" @@"))
            .ok_or(EditError::InvalidPatch)?
            .0;
        let (old, new) = header_ranges
            .split_once(" +")
            .ok_or(EditError::InvalidPatch)?;
        let (old_start, old_count) = range(old)?;
        let (new_start, new_count) = range(new)?;
        let old_count = OldLineCount::try_from(old_count)?;
        let new_count = NewLineCount::try_from(new_count)?;
        let mut draft = Draft {
            old_left: old_count,
            new_left: new_count,
            hunk: Self {
                header: header.to_owned(),
                body: Vec::new(),
                old_start: OldLine::try_from(old_start)?,
                new_start: NewLine::try_from(new_start)?,
                old_count,
                new_count,
            },
        };
        while draft.old_left.get() > 0 || draft.new_left.get() > 0 {
            draft.line(lines.next().ok_or(EditError::InvalidPatch)?)?;
        }
        if lines.peek() == Some(&NO_NEWLINE) {
            draft.line(lines.next().ok_or(EditError::InvalidPatch)?)?;
        }
        draft.finish()
    }
    /// Validate the legacy zero-context uniqueness rule without applying a hunk.
    pub fn check_unique_context(&self, base: &EditText) -> Result<(), EditError> {
        if self
            .body
            .iter()
            .any(|line| matches!(line, BodyLine::Context(_)))
        {
            return Ok(());
        }
        let removed: Vec<_> = self
            .body
            .iter()
            .filter_map(|line| match line {
                BodyLine::Removed(text) => Some(text.as_str()),
                _ => None,
            })
            .collect();
        if removed.is_empty() {
            return Ok(());
        }
        let needle = Zeroizing::new(removed.join("\n"));
        if needle.is_empty() {
            return Err(EditError::MissingMatch);
        }
        let mut matches = base.as_str().match_indices(needle.as_str());
        matches.next().ok_or(EditError::MissingMatch)?;
        if matches.next().is_some() {
            return Err(EditError::AmbiguousMatch);
        }
        Ok(())
    }
    /// Old-side coordinates and count retain distinct units.
    pub fn old_range(&self) -> (OldLine, OldLineCount) {
        (self.old_start, self.old_count)
    }
    /// New-side coordinates and count retain distinct units.
    pub fn new_range(&self) -> (NewLine, NewLineCount) {
        (self.new_start, self.new_count)
    }
    pub(super) fn render(&self, output: &mut super::Output) -> Result<(), EditError> {
        output.line(&self.header)?;
        for line in &self.body {
            match line {
                BodyLine::Context(text) => output.prefixed(" ", text)?,
                BodyLine::Removed(text) => output.prefixed("-", text)?,
                BodyLine::Added(text) => output.prefixed("+", text)?,
                BodyLine::NoNewline => output.line(NO_NEWLINE)?,
            }
        }
        Ok(())
    }
}
