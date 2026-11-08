//! Output policy: redaction of known sensitive tokens and bounded character capping.

use crate::constants::limits;

const SECRET_KEYS: &[&str] = &["api_key", "api-key", "secret", "password", "token", "auth"];

/// Redacted and character-capped tool output ready for model/history commit.
pub(crate) struct SanitizedToolOutput(String);

impl SanitizedToolOutput {
    /// Redact known token/secret patterns and enforce bounded character capping for model/history.
    pub(crate) fn sanitize(raw: &str) -> Self {
        let redacted = redact_secrets(raw);
        Self(cap_tool_output(&redacted, limits::MODEL_TOOL_OUTPUT_CHARS))
    }

    /// Borrow the sanitized output text.
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

/// Redact Bearer tokens, standard sk- API keys, and sensitive key-value pairs.
fn redact_secrets(text: &str) -> String {
    let text = redact_bearer(text);
    let text = redact_api_keys(&text);
    redact_kv_pairs(&text)
}

fn redact_bearer(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(pos) = rest.find("Bearer ") {
        out.push_str(&rest[..pos + 7]);
        out.push_str("[REDACTED]");
        let token_part = &rest[pos + 7..];
        let token_len = token_part
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '-' && c != '_' && c != '.')
            .unwrap_or(token_part.len());
        rest = &token_part[token_len..];
    }
    out.push_str(rest);
    out
}

fn redact_api_keys(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(pos) = rest.find("sk-") {
        let key_part = &rest[pos + 3..];
        let key_len = key_part
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '-' && c != '_')
            .unwrap_or(key_part.len());
        if key_len >= 18 {
            out.push_str(&rest[..pos]);
            out.push_str("[REDACTED-KEY]");
            rest = &key_part[key_len..];
        } else {
            out.push_str(&rest[..pos + 3]);
            rest = key_part;
        }
    }
    out.push_str(rest);
    out
}

fn find_next_secret_key(text: &str) -> Option<(usize, usize)> {
    let lower = text.to_ascii_lowercase();
    let mut earliest: Option<(usize, usize)> = None;
    for &key in SECRET_KEYS {
        if let Some(pos) = lower.find(key) {
            match earliest {
                Some((cur_pos, _)) if pos < cur_pos => earliest = Some((pos, key.len())),
                None => earliest = Some((pos, key.len())),
                _ => {}
            }
        }
    }
    earliest
}

fn is_secret_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | '+' | '=')
}

fn match_kv_separator_and_value(after_key: &str) -> Option<(usize, usize)> {
    let mut chars = after_key.char_indices().peekable();
    while let Some(&(_, c)) = chars.peek() {
        if c == '"' || c == '\'' || c == ' ' || c == '\t' {
            chars.next();
        } else {
            break;
        }
    }
    let colon_or_eq = chars.next()?;
    if colon_or_eq.1 != ':' && colon_or_eq.1 != '=' {
        return None;
    }
    let mut sep_end = colon_or_eq.0 + colon_or_eq.1.len_utf8();
    while let Some(&(idx, c)) = chars.peek() {
        if c == '"' || c == '\'' || c == ' ' || c == '\t' {
            chars.next();
            sep_end = idx + c.len_utf8();
        } else {
            break;
        }
    }
    let val_start = sep_end;
    let mut val_end = val_start;
    while let Some(&(idx, c)) = chars.peek() {
        if is_secret_char(c) {
            chars.next();
            val_end = idx + c.len_utf8();
        } else {
            break;
        }
    }
    let val_len = val_end.saturating_sub(val_start);
    if val_len >= 8 {
        Some((sep_end, val_len))
    } else {
        None
    }
}

fn redact_kv_pairs(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((pos, key_len)) = find_next_secret_key(rest) {
        out.push_str(&rest[..pos + key_len]);
        let after_key = &rest[pos + key_len..];
        if let Some((sep_len, val_len)) = match_kv_separator_and_value(after_key) {
            out.push_str(&after_key[..sep_len]);
            out.push_str("[REDACTED]");
            rest = &after_key[sep_len + val_len..];
        } else {
            let advance = after_key.chars().next().map_or(0, char::len_utf8);
            out.push_str(&after_key[..advance]);
            rest = &after_key[advance..];
        }
    }
    out.push_str(rest);
    out
}

/// Cap output to `max_chars`, preserving UTF-8 boundaries and stating omitted characters/bytes.
fn cap_tool_output(input: &str, max_chars: usize) -> String {
    let total_chars = input.chars().count();
    if total_chars <= max_chars {
        return input.to_owned();
    }
    let mut byte_index = 0;
    for (char_count, (idx, _)) in input.char_indices().enumerate() {
        if char_count == max_chars {
            byte_index = idx;
            break;
        }
    }
    let omitted_chars = total_chars.saturating_sub(max_chars);
    let omitted_bytes = input.len().saturating_sub(byte_index);
    let kept = &input[..byte_index];
    format!(
        "{kept}\n... [Output truncated: omitted {omitted_chars} chars ({omitted_bytes} bytes). Read remaining with read_file.]"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_tokens_are_redacted() {
        let input = "Authorization: Bearer secret-token-12345.abc\nNext";
        let out = redact_secrets(input);
        assert_eq!(out, "Authorization: Bearer [REDACTED]\nNext");
    }

    #[test]
    fn standard_api_keys_are_redacted() {
        let input = "export KEY=sk-12345678901234567890abcdef and more";
        let out = redact_secrets(input);
        assert_eq!(out, "export KEY=[REDACTED-KEY] and more");
    }

    #[test]
    fn kv_secret_pairs_are_redacted() {
        let input = r#"{"api_key": "topsecrettoken123", "password": "mypassword123"}"#;
        let out = redact_secrets(input);
        assert_eq!(
            out,
            r#"{"api_key": "[REDACTED]", "password": "[REDACTED]"}"#
        );
    }

    #[test]
    fn output_capping_states_omitted_chars_and_bytes_and_preserves_utf8() {
        let input = "ş".repeat(100);
        let out = cap_tool_output(&input, 10);
        assert!(out.starts_with(&"ş".repeat(10)));
        assert!(out.contains("omitted 90 chars (180 bytes)"));
    }
}
