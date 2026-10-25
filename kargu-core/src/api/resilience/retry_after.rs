//! Parse provider wait metadata once, without retaining untrusted header text.

use reqwest::header::HeaderValue;
use std::time::{Duration, SystemTime};

#[derive(Debug)]
enum Captured {
    Seconds(Duration),
    Date(SystemTime),
    Invalid,
    Exceeded,
}
/// Parsed response wait, not an arbitrary upstream diagnostic or credential.
#[derive(Debug)]
pub struct RetryAfter(Captured);
pub(super) enum ServerWait {
    Absent,
    Delay(Duration),
    TooLong,
}
impl From<&str> for RetryAfter {
    fn from(raw: &str) -> Self {
        let raw = raw.trim_matches([' ', '\t']);
        if raw.len() > 128 {
            return Self(Captured::Exceeded);
        }
        if raw.is_empty() {
            return Self(Captured::Invalid);
        }
        if raw.bytes().all(|byte| byte.is_ascii_digit()) {
            return Self(match raw.parse::<u64>() {
                Ok(seconds) => Captured::Seconds(Duration::from_secs(seconds)),
                Err(_) => Captured::Exceeded,
            });
        }
        Self(match httpdate::parse_http_date(raw) {
            Ok(date) => Captured::Date(date),
            Err(_) => Captured::Invalid,
        })
    }
}
impl From<&HeaderValue> for RetryAfter {
    fn from(value: &HeaderValue) -> Self {
        match value.to_str() {
            Ok(raw) => Self::from(raw),
            Err(_) => Self(Captured::Invalid),
        }
    }
}
impl RetryAfter {
    pub(super) fn wait(&self, now: SystemTime, limit: Duration) -> ServerWait {
        let delay = match self.0 {
            Captured::Seconds(delay) => delay,
            Captured::Date(at) => at.duration_since(now).unwrap_or(Duration::ZERO),
            Captured::Invalid => return ServerWait::Absent,
            Captured::Exceeded => return ServerWait::TooLong,
        };
        if delay > limit {
            ServerWait::TooLong
        } else {
            ServerWait::Delay(delay)
        }
    }
    /// Canonical validated protocol value for the temporary editor error port.
    pub fn wire(&self) -> Option<String> {
        match self.0 {
            Captured::Seconds(delay) => Some(delay.as_secs().to_string()),
            Captured::Date(at) => Some(httpdate::fmt_http_date(at)),
            Captured::Invalid | Captured::Exceeded => None,
        }
    }
    /// Capture/numeric bounds were exceeded; never reinterpret as no header.
    pub fn exceeded(&self) -> bool {
        matches!(self.0, Captured::Exceeded)
    }
}
