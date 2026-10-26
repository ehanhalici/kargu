//! Streaming range capture and one presentation policy for disk and live text.

use super::{ExcerptCharBudget, FileExcerpt, LineNumber, ScanCharBudget, Snapshot, Window};
use crate::{error::CoreError, security::file::checkpoint};
use std::time::Instant;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

struct ScannedChars(usize);
pub(super) struct Scanner<'a> {
    window: &'a Window,
    scan: &'a ScanCharBudget,
    output: &'a ExcerptCharBudget,
    chars: ScannedChars,
    line: LineNumber,
    captured: ScannedChars,
    text: Zeroizing<String>,
    stopped: bool,
    complete: bool,
    carriage: bool,
    last_newline: bool,
}
impl<'a> Scanner<'a> {
    pub(super) fn new(
        window: &'a Window,
        scan: &'a ScanCharBudget,
        output: &'a ExcerptCharBudget,
    ) -> Self {
        Self {
            window,
            scan,
            output,
            chars: ScannedChars(0),
            line: LineNumber(1),
            captured: ScannedChars(0),
            text: Zeroizing::new(String::new()),
            stopped: false,
            complete: false,
            carriage: false,
            last_newline: false,
        }
    }
    pub(super) fn finished(&self) -> bool {
        self.stopped
    }
    fn character(&mut self, character: char) -> Result<(), CoreError> {
        if self.chars.0 >= self.scan.0 {
            self.stopped = true;
            return Ok(());
        }
        self.chars.0 = self.chars.0.saturating_add(1);
        if self.line.0 >= self.window.from.0 {
            self.text.push(character);
            self.captured.0 = self.captured.0.saturating_add(1);
            // One lookahead character distinguishes truncation from exact EOF.
            if self.captured.0 > self.output.0 {
                self.stopped = true;
            }
        }
        self.last_newline = character == '\n';
        if character == '\n' {
            if self.window.to.is_some_and(|to| self.line.0 >= to.0) {
                self.stopped = true;
            }
            self.line = self.line.next()?;
        }
        Ok(())
    }
    pub(super) fn ingest(
        &mut self,
        text: &str,
        complete: bool,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<(), CoreError> {
        let mut characters = text.chars().peekable();
        while let Some(character) = characters.next() {
            if self.stopped {
                return Ok(());
            }
            checkpoint(cancel, deadline)?;
            if self.carriage {
                self.carriage = false;
                if character != '\n' {
                    self.character('\r')?;
                    if self.stopped {
                        return Ok(());
                    }
                }
            }
            if character == '\r' {
                self.carriage = true;
            } else {
                self.character(character)?;
            }
            if complete && characters.peek().is_none() {
                // A terminal newline is a separator, not an extra empty source line.
                self.complete = !self.carriage;
            }
        }
        if complete && !self.stopped {
            if self.carriage {
                self.carriage = false;
                self.character('\r')?;
            }
            self.complete = true;
        }
        Ok(())
    }
    pub(super) fn into_snapshot(self) -> Snapshot {
        let last = self
            .line
            .0
            .saturating_sub(u64::from(self.last_newline))
            .max(1);
        Snapshot {
            available: self.window.from.0 <= last,
            text: self.text,
            complete: self.complete,
        }
    }
}

pub(super) fn excerpt(
    path: &str,
    window: &Window,
    output: &ExcerptCharBudget,
    snapshot: Snapshot,
    bytes_read: usize,
) -> Result<FileExcerpt, CoreError> {
    if !snapshot.available {
        return Err(CoreError::InvalidValue {
            field: if snapshot.complete {
                "LinePastEof"
            } else {
                "FileScanExhausted"
            },
        });
    }
    let boundary = snapshot.text.ends_with('\n');
    let text = snapshot.text.strip_suffix('\n').unwrap_or(&snapshot.text);
    let mut remaining = output.0;
    let mut pieces = Vec::new();
    let mut line = window.from;
    let mut last = line.0;
    let mut total = None;
    let mut truncated = false;
    let mut lines = text.split('\n').peekable();
    while let Some(source) = lines.next() {
        if window.to.is_some_and(|to| line.0 > to.0) {
            break;
        }
        last = line.0;
        let prefix = format!("{} | ", line.0);
        let piece: String = prefix
            .chars()
            .chain(source.chars())
            .take(remaining)
            .collect();
        let length = piece.chars().count();
        let cut = prefix
            .chars()
            .count()
            .saturating_add(source.chars().count())
            > remaining;
        remaining = remaining.saturating_sub(length.saturating_add(1));
        pieces.push(piece);
        if cut {
            truncated = true;
            break;
        }
        if lines.peek().is_none() {
            if snapshot.complete {
                total = Some(line.0);
            } else {
                truncated = !boundary || window.to.is_none_or(|to| line.0 < to.0);
            }
            break;
        }
        if remaining == 0 {
            truncated = window.to.is_none_or(|to| line.0 < to.0);
            break;
        }
        line = line.next()?;
    }
    let total = total.map_or_else(|| "unknown".to_owned(), |total| total.to_string());
    let marker = if truncated { ", truncated" } else { "" };
    let notice = if truncated {
        "\n... [truncated; request a smaller line range]"
    } else {
        ""
    };
    Ok(FileExcerpt {
        text: format!(
            "(file {path}, lines {}-{last} of {total}{marker})\n{}{notice}",
            window.from.0,
            pieces.join("\n")
        ),
        bytes_read,
        truncated,
    })
}
