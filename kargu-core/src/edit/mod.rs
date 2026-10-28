//! Native proposal, review and transaction domain. Editor writes require a later grant.
//!
//! Text/framing preparation has no filesystem or editor side effects. A parsed
//! patch or a content hash is evidence, never authority to apply an editor edit.

pub mod patch;
pub(crate) mod prepare;
pub mod proposal;
pub mod review;
pub mod types;

/// Closed edit-domain failures. Display never includes source text or filenames.
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum EditError {
    /// The installed Git refused the isolated patch or did not complete safely.
    #[error("isolated patch preparation failed")]
    PatchFailed,
    /// The requested existing target is absent.
    #[error("edit target does not exist")]
    MissingTarget,
    /// Live or filesystem source evidence changed before preparation.
    #[error("edit source conflict")]
    Conflict,
    /// A bounded content, count or collection exceeded its limit.
    #[error("edit resource limit exceeded")]
    Limit,
    /// A model target is empty, absolute, reserved or traverses a parent.
    #[error("invalid edit path")]
    InvalidPath,
    /// Text/framing does not follow the supported Unified Diff grammar.
    #[error("invalid unified patch")]
    InvalidPatch,
    /// Binary, rename/copy, executable modes and legacy directives are absent.
    #[error("unsupported patch operation")]
    UnsupportedPatch,
    /// A replace or zero-context deletion has no literal match.
    #[error("edit context does not match")]
    MissingMatch,
    /// A replace or zero-context deletion lacks unique context.
    #[error("edit context is ambiguous")]
    AmbiguousMatch,
    /// A content hash or coordinate failed its closed wire boundary.
    #[error("invalid edit evidence")]
    InvalidEvidence,
}
