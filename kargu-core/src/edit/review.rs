//! Review text interpretation is native domain data, not permission or application.
use super::types::EditText;
use serde::Deserialize;

/// Explicit UI input. Interrupt and reject are never inferred from response text.
#[derive(Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case", deny_unknown_fields)]
pub enum ReviewDecision {
    /// User accepted the current review text; it still needs native validation.
    Accept {
        /// Bounded widened content from the captured review buffer.
        content: EditText,
    },
    /// User or unavailable review UI refused the proposal.
    /// An empty struct variant keeps unknown-field rejection at the wire boundary.
    Reject {},
    /// The user explicitly interrupted review.
    Interrupt {},
}
/// Text interpretation before a revision-bound approval and editor apply receipt.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReviewKind {
    /// Requested and original text coincide; no mutation is needed.
    Unchanged,
    /// User retained the original or rejected the review.
    Rejected,
    /// Explicit interrupted input, independent of content equality.
    Interrupted,
    /// Accepted text is exactly the original requested proposal.
    AcceptedProposal,
    /// Accepted text is a different proposal requiring a new native revision.
    AcceptedRevision,
}
/// Source-bearing assessment. It is deliberately not serializable execution authority.
pub struct ReviewAssessment {
    kind: ReviewKind,
    accepted: Option<EditText>,
}
impl ReviewAssessment {
    /// Interpret actual reviewed text without claiming any editor side effects.
    pub fn assess(base: &EditText, proposed: &EditText, decision: ReviewDecision) -> Self {
        let (kind, accepted) = match decision {
            ReviewDecision::Reject {} => (ReviewKind::Rejected, None),
            ReviewDecision::Interrupt {} => (ReviewKind::Interrupted, None),
            ReviewDecision::Accept { content } if content.as_str() == base.as_str() => (
                if proposed.as_str() == base.as_str() {
                    ReviewKind::Unchanged
                } else {
                    ReviewKind::Rejected
                },
                None,
            ),
            ReviewDecision::Accept { content } if content.as_str() == proposed.as_str() => {
                (ReviewKind::AcceptedProposal, Some(content))
            }
            ReviewDecision::Accept { content } => (ReviewKind::AcceptedRevision, Some(content)),
        };
        Self { kind, accepted }
    }
    /// Whether the review refused, retained, accepted or revised the proposal.
    pub fn kind(&self) -> ReviewKind {
        self.kind
    }
    /// Borrow accepted text for further native preparation; never a write grant.
    pub fn accepted(&self) -> Option<&EditText> {
        self.accepted.as_ref()
    }
}
