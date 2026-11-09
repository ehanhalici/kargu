//! Whether a canonical request payload streams its response.

/// Stream delivery mode for a canonical payload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PayloadStream(bool);

impl PayloadStream {
    /// Non-streaming single-response payload.
    pub const PLAIN: Self = Self(false);
    /// Server-sent events streaming payload.
    pub const STREAMING: Self = Self(true);

    /// Whether streaming mode is enabled.
    pub fn is_streaming(&self) -> bool {
        self.0
    }
}

impl From<bool> for PayloadStream {
    fn from(value: bool) -> Self {
        Self(value)
    }
}
