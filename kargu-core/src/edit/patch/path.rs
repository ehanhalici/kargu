//! Git path quoting at the untrusted patch boundary, never shell quoting.
use crate::edit::{EditError, types::EditPath};

pub(super) fn parse(raw: &str, prefix: &str) -> Result<Option<EditPath>, EditError> {
    let text = raw.split('\t').next().ok_or(EditError::InvalidPath)?.trim();
    let decoded = if text.starts_with('"') {
        unquote(text)?
    } else {
        text.to_owned()
    };
    if decoded == "/dev/null" {
        return Ok(None);
    }
    EditPath::try_from(decoded.strip_prefix(prefix).unwrap_or(&decoded).to_owned()).map(Some)
}
/// Git's up-to-three-digit octal escape; `first` is the digit already read.
fn octal(first: u8, input: &mut std::iter::Peekable<std::str::Bytes<'_>>) -> Result<u8, EditError> {
    let mut value = u16::from(first - b'0');
    for _ in 0..2 {
        let Some(digit) = input.next_if(|b| matches!(b, b'0'..=b'7')) else {
            break;
        };
        value = value
            .checked_mul(8)
            .and_then(|n| n.checked_add(u16::from(digit - b'0')))
            .ok_or(EditError::InvalidPath)?;
    }
    u8::try_from(value).map_err(|_| EditError::InvalidPath)
}
fn unquote(text: &str) -> Result<String, EditError> {
    let text = text
        .strip_prefix('"')
        .and_then(|t| t.strip_suffix('"'))
        .ok_or(EditError::InvalidPath)?;
    let mut input = text.bytes().peekable();
    let mut bytes = Vec::with_capacity(text.len());
    while let Some(byte) = input.next() {
        if byte != b'\\' {
            if byte == b'"' {
                return Err(EditError::InvalidPath);
            }
            bytes.push(byte);
            continue;
        }
        let escaped = input.next().ok_or(EditError::InvalidPath)?;
        let byte = match escaped {
            b'"' | b'\\' => escaped,
            b'a' => 7,
            b'b' => 8,
            b't' => 9,
            b'n' => 10,
            b'v' => 11,
            b'f' => 12,
            b'r' => 13,
            b'0'..=b'7' => octal(escaped, &mut input)?,
            _ => return Err(EditError::InvalidPath),
        };
        bytes.push(byte);
    }
    String::from_utf8(bytes).map_err(|_| EditError::InvalidPath)
}
pub(super) fn quote(prefix: &str, path: &EditPath) -> Result<String, EditError> {
    serde_json::to_string(&format!("{prefix}{}", path.as_str())).map_err(|_| EditError::InvalidPath)
}
