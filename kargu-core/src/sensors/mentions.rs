//! Dynamic context mention parser, attachment resolution, and prompt budget engine.

use super::types::SourceLine;
use crate::domain::evidence::EditPath;
use serde::{Deserialize, Serialize};

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
    target_id: String,
    /// Raw slice string from user prompt.
    raw: String,
    /// UTF-8 start byte index.
    start: usize,
    /// UTF-8 end byte index.
    end: usize,
    /// Parsed target kind and value.
    pub target: MentionTarget,
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

    /// Rule: an `@` right after a word character is an email address, not a mention.
    fn preceded_by_word(&self, idx: usize) -> bool {
        self.text
            .get(..idx)
            .and_then(|s| s.chars().last())
            .is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '.')
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

            let found =
                (bytes.get(idx) == Some(&b'@') && !self.preceded_by_word(idx) && idx + 1 < len)
                    .then(|| self.try_parse_target(idx + 1))
                    .flatten();
            if let Some((target, span_len)) = found {
                let Some(span_str) = self.text.get(idx..idx + span_len + 1) else {
                    break;
                };
                let full = maximum.is_some_and(|limit| results.len() >= limit);
                if full {
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

        if let Some(rest) = remainder.strip_prefix("buffer:") {
            let (buff_name, eaten) = parse_token_or_quoted(rest)?;
            return Some((MentionTarget::Buffer { name: buff_name }, 7 + eaten));
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
            return parse_folder_target(rest);
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
        parse_double_quoted(input)
    } else {
        bare_token(input, |c| {
            c.is_whitespace() || matches!(c, ')' | ']' | '}' | '>' | ',' | ';')
        })
    }
}

fn parse_token_or_quoted_until_colon(input: &str) -> Option<(String, usize)> {
    if input.is_empty() {
        return None;
    }
    if input.starts_with('"') {
        parse_double_quoted(input)
    } else {
        bare_token(input, |c| c == ':' || c.is_whitespace())
    }
}

/// A `"…"` token with backslash escapes; an unclosed quote is no token.
fn parse_double_quoted(input: &str) -> Option<(String, usize)> {
    let mut out = String::new();
    let mut chars = input.char_indices().skip(1);
    while let Some((idx, c)) = chars.next() {
        match c {
            '\\' => out.extend(chars.next().map(|(_, next)| next)),
            '"' => return Some((out, idx + 1)),
            _ => out.push(c),
        }
    }
    None
}

/// The non-empty prefix of `input` before the first `stop` character.
fn bare_token(input: &str, stop: impl Fn(char) -> bool) -> Option<(String, usize)> {
    let end = input.find(stop).unwrap_or(input.len());
    let slice = input.get(..end).filter(|slice| !slice.is_empty())?;
    Some((slice.to_string(), end))
}

fn parse_folder_target(rest: &str) -> Option<(MentionTarget, usize)> {
    let (path_str, eaten_path) =
        parse_token_or_quoted_until_colon(rest).or_else(|| parse_token_or_quoted(rest))?;
    let path = EditPath::try_from(path_str).ok()?;
    let (depth, max_files, extra_eaten) = parse_folder_depth_limits(rest, eaten_path);
    Some((
        MentionTarget::Folder {
            path,
            depth,
            max_files,
        },
        7 + eaten_path + extra_eaten,
    ))
}

fn parse_folder_depth_limits(
    rest: &str,
    eaten_path: usize,
) -> (Option<usize>, Option<usize>, usize) {
    let Some(after_colon) = rest.get(eaten_path..).and_then(|s| s.strip_prefix(':')) else {
        return (None, None, 0);
    };
    let Some((depth_str, eaten_d)) = bare_token(after_colon, |c| {
        c == ':' || c.is_whitespace() || matches!(c, ')' | ']' | ',' | ';' | '.' | '!' | '?')
    }) else {
        return (None, None, 0);
    };
    let Ok(d) = depth_str.parse::<usize>() else {
        return (None, None, 0);
    };
    let (max_files, eaten_m) = parse_folder_max_files(after_colon, eaten_d);
    (Some(d), max_files, 1 + eaten_d + eaten_m)
}

fn parse_folder_max_files(after_colon: &str, eaten_d: usize) -> (Option<usize>, usize) {
    let Some(after_colon2) = after_colon.get(eaten_d..).and_then(|s| s.strip_prefix(':')) else {
        return (None, 0);
    };
    let Some((max_str, eaten_m)) = bare_token(after_colon2, |c| {
        c.is_whitespace() || matches!(c, ')' | ']' | ',' | ';' | '.' | '!' | '?')
    }) else {
        return (None, 0);
    };
    let Ok(m) = max_str.parse::<usize>() else {
        return (None, 0);
    };
    (Some(m), 1 + eaten_m)
}

fn parse_range_spec(input: &str) -> Option<(String, usize)> {
    bare_token(input, |c| {
        c.is_whitespace() || matches!(c, ')' | ']' | ',' | ';')
    })
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

    #[test]
    fn folder_mentions_parse_depth_and_max_files() -> Result<(), Box<dyn std::error::Error>> {
        let spans =
            MentionLexer::new("check @folder:src then @folder:src:2 and @folder:\"lib dir\":3:50.")
                .parse();
        assert_eq!(spans.len(), 3);
        assert_eq!(
            spans[0].target,
            MentionTarget::Folder {
                path: EditPath::try_from("src".to_string())?,
                depth: None,
                max_files: None,
            }
        );
        assert_eq!(
            spans[1].target,
            MentionTarget::Folder {
                path: EditPath::try_from("src".to_string())?,
                depth: Some(2),
                max_files: None,
            }
        );
        assert_eq!(
            spans[2].target,
            MentionTarget::Folder {
                path: EditPath::try_from("lib dir".to_string())?,
                depth: Some(3),
                max_files: Some(50),
            }
        );
        Ok(())
    }
}
