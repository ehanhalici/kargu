//! Units derived once at the captured API framing boundary.

use super::{ByteLimit, CoreError};

/// UTF-8 body-page capacity, distinct from a transport frame's byte limit.
/// Worst-case JSON escaping and envelope space are reserved before admission.
///
/// A frame bound cannot be used as a body-page bound without conversion:
/// ```compile_fail
/// use kargu_core::domain::{ApiPageBytes, ByteLimit};
/// fn wrong_unit(frame: ByteLimit) { let _: ApiPageBytes = frame; }
/// ```
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ApiPageBytes(usize);

impl TryFrom<ByteLimit> for ApiPageBytes {
    type Error = CoreError;
    fn try_from(frame: ByteLimit) -> Result<Self, CoreError> {
        let capacity = frame
            .as_usize()
            .saturating_sub(512)
            .saturating_div(6)
            .min(32 * 1024);
        // Four bytes always fit the next complete UTF-8 scalar. Once captured,
        // publishers need neither a zero-size check nor a progress recheck.
        if capacity < 4 {
            return Err(CoreError::InvalidValue {
                field: "ApiPageBytes",
            });
        }
        Ok(Self(capacity))
    }
}

impl ApiPageBytes {
    /// Extract only at the UTF-8 slicing/allocation boundary.
    pub const fn as_usize(self) -> usize {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn pages_reserve_framing_and_always_fit_a_complete_scalar() -> TestResult {
        for small in [1, 512, 535] {
            assert!(ApiPageBytes::try_from(ByteLimit::try_from(small)?).is_err());
        }
        for (frame, expected) in [(536, 4), (1024, 85), (1048576, 32768), (usize::MAX, 32768)] {
            let page = ApiPageBytes::try_from(ByteLimit::try_from(frame)?)?;
            assert_eq!(page.as_usize(), expected);
            let text = "🦀🦀";
            assert!(text.floor_char_boundary(page.as_usize().min(text.len())) > 0);
        }
        Ok(())
    }
}
