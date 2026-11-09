//! Depends back on a.
/// Beta.
pub struct Beta;
/// Uses a.
pub fn wrap(alpha: crate::a::Alpha) -> crate::a::Alpha {
    alpha
}
