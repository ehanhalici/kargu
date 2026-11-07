//! Dynamic context mention parser, attachment resolution, and prompt budget engine.

use super::{
    coordinates::SourceRange,
    types::{DocumentId, SensorText, SourceLine},
};
use crate::edit::types::{ContentHash, EditPath};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Parsed mention target kind.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MentionTarget {
    /// Explicit `@file:path` mention.
    File {
        /// Target relative or project path.
        path: EditPath,
    },
    /// Live editor buffer `@buff:name` mention.
    Buffer {
        /// Buffer name or pattern.
        name: String,
    },
    /// Symbol definition `@sym:symbol` mention.
    Symbol {
        /// Symbol identifier name.
        name: String,
    },
    /// Working tree Git diff `@git:diff`.
    GitDiff,
    /// Staged index Git diff `@git:staged`.
    GitStaged,
    /// Exact line range `@line:path:start-end`.
    LineRange {
        /// Target file path.
        path: EditPath,
        /// One-based start line.
        start: SourceLine,
        /// One-based end line.
        end: SourceLine,
    },
    /// Directory listing `@folder:path`.
    Folder {
        /// Target folder path.
        path: EditPath,
        /// Optional maximum recursion depth.
        #[serde(skip_serializing_if = "Option::is_none")]
        depth: Option<usize>,
        /// Optional maximum file count.
        #[serde(skip_serializing_if = "Option::is_none")]
        max_files: Option<usize>,
    },
    /// Legacy `@path` file mention.
    LegacyPath {
        /// Target file path.
        path: EditPath,
    },
    /// Legacy `@file::symbol` mention.
    LegacyFileSymbol {
        /// Target file path.
        path: EditPath,
        /// Target symbol name.
        symbol: String,
    },
}

/// A parsed mention span inside the prompt text.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MentionSpan {
    /// Unique mention target identity.
    pub target_id: String,
    /// Raw slice string from user prompt.
    pub raw: String,
    /// UTF-8 start byte index.
    pub start: usize,
    /// UTF-8 end byte index.
    pub end: usize,
    /// Parsed target kind and value.
    pub target: MentionTarget,
}

/// Resolution status of an attachment.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResolutionStatus {
    /// Attachment was fully and cleanly resolved.
    Resolved,
    /// Target file, buffer, or symbol was not found.
    NotFound,
    /// Target source provider is unavailable.
    Unavailable,
    /// Reading the target was rejected by policy or root boundaries.
    Rejected,
    /// Target is a binary file.
    Binary,
    /// Target content was truncated due to budget or limits.
    Truncated,
}

/// An immutable resolved context attachment.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextAttachment {
    /// Unique mention target identity.
    pub target_id: String,
    /// Parsed target reference.
    pub target: MentionTarget,
    /// Attachment resolution status.
    pub status: ResolutionStatus,
    /// Canonical file path on disk, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    /// Live document identity, if captured from RAM.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_id: Option<DocumentId>,
    /// Document modification tick or file revision.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    /// Content hash for integrity recheck.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hash: Option<ContentHash>,
    /// Range of text within the target, if sliced.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<SourceRange>,
    /// Bounded snapshot content text.
    pub content: SensorText,
    /// Whether the editor buffer had unsaved modifications.
    pub dirty: bool,
    /// Whether the content was truncated to fit the context budget.
    pub truncated: bool,
    /// Total UTF-8 byte count of the content.
    pub byte_count: usize,
    /// Conservative token estimate for the attachment.
    pub token_estimate: usize,
}

impl ContextAttachment {
    /// Estimate conservative tokens: ceil(bytes / 3.0) + framing overhead.
    pub fn estimate_tokens(bytes: usize) -> usize {
        bytes.div_ceil(3).saturating_add(16)
    }

    /// Render XML-escaped data role context block.
    pub fn render_xml(&self) -> String {
        let mut out = String::new();
        out.push_str("<context_attachment");
        out.push_str(&format!(" target_id=\"{}\"", escape_xml(&self.target_id)));
        out.push_str(&format!(" status=\"{:?}\"", self.status));
        if let Some(p) = &self.path {
            out.push_str(&format!(
                " path=\"{}\"",
                escape_xml(&p.display().to_string())
            ));
        }
        if self.dirty {
            out.push_str(" dirty=\"true\"");
        }
        if self.truncated {
            out.push_str(" truncated=\"true\"");
        }
        out.push_str(">\n");
        out.push_str(&escape_xml(self.content.as_str()));
        out.push_str("\n</context_attachment>\n");
        out
    }
}

/// Escape XML delimiter characters to prevent prompt delimiter injection.
pub fn escape_xml(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            other => out.push(other),
        }
    }
    out
}

/// Native mention lexer.
pub struct MentionLexer<'a> {
    text: &'a str,
}

impl<'a> MentionLexer<'a> {
    /// Construct a new mention lexer over prompt text.
    pub fn new(text: &'a str) -> Self {
        Self { text }
    }

    /// Parse all valid mentions in prompt text.
    pub fn parse(&self) -> Vec<MentionSpan> {
        self.parse_inner(None).unwrap_or_default()
    }

    pub(crate) fn parse_bounded(&self) -> Option<Vec<MentionSpan>> {
        self.parse_inner(Some(crate::constants::limits::MENTION_TARGETS))
    }

    fn parse_inner(&self, maximum: Option<usize>) -> Option<Vec<MentionSpan>> {
        let mut results = Vec::new();
        let bytes = self.text.as_bytes();
        let len = bytes.len();
        let mut idx = 0;
        let mut in_fenced_code = false;
        let mut seq_id = 0usize;

        while idx < len {
            // Check for fenced code block toggle (```)
            if bytes.get(idx..idx + 3) == Some(b"```") {
                in_fenced_code = !in_fenced_code;
                idx += 3;
                continue;
            }

            if in_fenced_code {
                idx += 1;
                continue;
            }

            if bytes.get(idx) == Some(&b'@') {
                // Rule: do not match email address (e.g. user@example.com)
                let preceded_by_word = if idx > 0 {
                    let prev = self.text.get(..idx).and_then(|s| s.chars().last());
                    prev.is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '.')
                } else {
                    false
                };

                if !preceded_by_word
                    && idx + 1 < len
                    && let Some((target, span_len)) = self.try_parse_target(idx + 1)
                {
                    let Some(span_str) = self.text.get(idx..idx + span_len + 1) else {
                        break;
                    };
                    if maximum.is_some_and(|limit| results.len() >= limit) {
                        return None;
                    }
                    seq_id += 1;
                    results.push(MentionSpan {
                        target_id: format!("mention-{}", seq_id),
                        raw: span_str.to_string(),
                        start: idx,
                        end: idx + span_len + 1,
                        target,
                    });
                    idx += span_len + 1;
                    continue;
                }
            }

            idx += 1;
        }

        Some(results)
    }

    fn try_parse_target(&self, start: usize) -> Option<(MentionTarget, usize)> {
        let remainder = &self.text[start..];
        if remainder.is_empty() {
            return None;
        }

        if let Some(rest) = remainder.strip_prefix("file:") {
            let (path_str, eaten) = parse_token_or_quoted(rest)?;
            let path = EditPath::try_from(path_str).ok()?;
            return Some((MentionTarget::File { path }, 5 + eaten));
        }

        if let Some(rest) = remainder.strip_prefix("buff:") {
            let (buff_name, eaten) = parse_token_or_quoted(rest)?;
            return Some((MentionTarget::Buffer { name: buff_name }, 5 + eaten));
        }

        if let Some(rest) = remainder.strip_prefix("sym:") {
            let (sym_name, eaten) = parse_token_or_quoted(rest)?;
            return Some((MentionTarget::Symbol { name: sym_name }, 4 + eaten));
        }

        if remainder.starts_with("git:") {
            let (token, _) = parse_token_or_quoted(remainder)?;
            let token = token.trim_end_matches(['.', '!', '?', ':']);
            return match token {
                "git:diff" => Some((MentionTarget::GitDiff, token.len())),
                "git:staged" => Some((MentionTarget::GitStaged, token.len())),
                _ => None,
            };
        }

        if let Some(rest) = remainder.strip_prefix("line:") {
            let (path_str, eaten_path) = parse_token_or_quoted_until_colon(rest)?;
            let after_colon = rest.get(eaten_path..)?.strip_prefix(':')?;
            let (range_str, eaten_range) = parse_range_spec(after_colon)?;
            let (start_line, end_line) = parse_lines(&range_str)?;
            let path = EditPath::try_from(path_str).ok()?;
            return Some((
                MentionTarget::LineRange {
                    path,
                    start: start_line,
                    end: end_line,
                },
                5 + eaten_path + 1 + eaten_range,
            ));
        }

        if let Some(rest) = remainder.strip_prefix("folder:") {
            let (path_str, eaten) = parse_token_or_quoted(rest)?;
            let path = EditPath::try_from(path_str).ok()?;
            return Some((
                MentionTarget::Folder {
                    path,
                    depth: None,
                    max_files: None,
                },
                7 + eaten,
            ));
        }

        let (first_token, eaten) = parse_token_or_quoted(remainder)?;
        let (first_token, eaten) = if remainder.starts_with(TOKEN_QUOTES) {
            (first_token, eaten)
        } else {
            trim_sentence_end(first_token, eaten)
        };
        if first_token.is_empty() {
            return None;
        }
        if let Some((file_part, sym_part)) = first_token.split_once("::")
            && !file_part.is_empty()
            && !sym_part.is_empty()
        {
            let path = EditPath::try_from(file_part.to_string()).ok()?;
            return Some((
                MentionTarget::LegacyFileSymbol {
                    path,
                    symbol: sym_part.to_string(),
                },
                eaten,
            ));
        }

        if first_token.contains('.') || first_token.contains('/') || first_token.contains('\\') {
            let path = EditPath::try_from(first_token).ok()?;
            return Some((MentionTarget::LegacyPath { path }, eaten));
        }

        None
    }
}

/// Quote characters that enclose a whole mention token.
const TOKEN_QUOTES: [char; 3] = ['"', '`', '\''];

/// Remove sentence punctuation that follows an unquoted token, returning the
/// token and the bytes it still covers.
fn trim_sentence_end(token: String, eaten: usize) -> (String, usize) {
    let trimmed = token.trim_end_matches(['.', ',', ':', ';', '!', '?', '"', '\'', '`']);
    let removed = token.len() - trimmed.len();
    (trimmed.to_owned(), eaten - removed)
}

fn parse_token_or_quoted(input: &str) -> Option<(String, usize)> {
    if input.is_empty() {
        return None;
    }
    if let Some(quote) = input.chars().next().filter(|c| *c == '`' || *c == '\'') {
        // Backtick and single quotes take no escapes; an unclosed one is no token.
        let body = input.get(quote.len_utf8()..)?;
        let close = body.find(quote)?;
        let token = body.get(..close)?;
        if token.is_empty() {
            return None;
        }
        return Some((token.to_owned(), close + 2 * quote.len_utf8()));
    }
    if input.starts_with('"') {
        let mut out = String::new();
        let mut chars = input.char_indices().skip(1);
        while let Some((idx, c)) = chars.next() {
            if c == '\\' {
                if let Some((_, next_c)) = chars.next() {
                    out.push(next_c);
                }
            } else if c == '"' {
                return Some((out, idx + 1));
            } else {
                out.push(c);
            }
        }
        None
    } else {
        let end = input
            .find(|c: char| {
                c.is_whitespace()
                    || c == ')'
                    || c == ']'
                    || c == '}'
                    || c == '>'
                    || c == ','
                    || c == ';'
            })
            .unwrap_or(input.len());
        if end == 0 {
            None
        } else {
            let slice = input.get(..end)?;
            Some((slice.to_string(), end))
        }
    }
}

fn parse_token_or_quoted_until_colon(input: &str) -> Option<(String, usize)> {
    if input.is_empty() {
        return None;
    }
    if input.starts_with('"') {
        let mut out = String::new();
        let mut chars = input.char_indices().skip(1);
        while let Some((idx, c)) = chars.next() {
            if c == '\\' {
                if let Some((_, next_c)) = chars.next() {
                    out.push(next_c);
                }
            } else if c == '"' {
                return Some((out, idx + 1));
            } else {
                out.push(c);
            }
        }
        None
    } else {
        let end = input
            .find(|c: char| c == ':' || c.is_whitespace())
            .unwrap_or(input.len());
        if end == 0 {
            None
        } else {
            let slice = input.get(..end)?;
            Some((slice.to_string(), end))
        }
    }
}

fn parse_range_spec(input: &str) -> Option<(String, usize)> {
    let end = input
        .find(|c: char| c.is_whitespace() || c == ')' || c == ']' || c == ',' || c == ';')
        .unwrap_or(input.len());
    if end == 0 {
        None
    } else {
        let slice = input.get(..end)?;
        Some((slice.to_string(), end))
    }
}

fn parse_lines(spec: &str) -> Option<(SourceLine, SourceLine)> {
    let (s_str, e_str) = spec.split_once('-')?;
    let start_num: u64 = s_str.parse().ok()?;
    let end_num: u64 = e_str.parse().ok()?;
    if start_num == 0 || end_num == 0 || start_num > end_num {
        return None;
    }
    let start = SourceLine::try_from(start_num).ok()?;
    let end = SourceLine::try_from(end_num).ok()?;
    Some((start, end))
}

#[cfg(test)]
mod quoting_tests {
    use super::*;

    fn paths(text: &str) -> Vec<(String, String)> {
        MentionLexer::new(text)
            .parse()
            .into_iter()
            .map(|span| {
                let path = match span.target {
                    MentionTarget::LegacyPath { path } => path.as_str().to_owned(),
                    MentionTarget::LegacyFileSymbol { path, symbol } => {
                        format!("{}::{symbol}", path.as_str())
                    }
                    other => format!("{other:?}"),
                };
                (span.raw, path)
            })
            .collect()
    }

    #[test]
    fn quoted_and_sentence_final_tokens_keep_only_the_path() {
        assert_eq!(
            paths("see @src/a.el, (@\"b.py\"). also @`c.go`. and @'d e.rs'!"),
            vec![
                ("@src/a.el".into(), "src/a.el".into()),
                ("@\"b.py\"".into(), "b.py".into()),
                ("@`c.go`".into(), "c.go".into()),
                ("@'d e.rs'".into(), "d e.rs".into()),
            ]
        );
        assert_eq!(
            paths("read @a.txt. Then @b.el::fn? Done @c.md!"),
            vec![
                ("@a.txt".into(), "a.txt".into()),
                ("@b.el::fn".into(), "b.el::fn".into()),
                ("@c.md".into(), "c.md".into()),
            ]
        );
        assert!(paths("unclosed @`x.rs and @. alone").is_empty());
    }
}
