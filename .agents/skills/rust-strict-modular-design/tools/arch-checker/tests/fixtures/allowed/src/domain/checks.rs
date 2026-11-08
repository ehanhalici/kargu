//! Out-of-line test module: excluded like an inline `#[cfg(test)]` one.

pub fn helper(raw: u64) -> u64 {
    Some(raw).unwrap()
}
