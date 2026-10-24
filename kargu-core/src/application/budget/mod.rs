//! Single-writer exact attempt meter. Sealing revokes ingress, not outstanding debt.
//!
//! A sealed meter cannot admit another attempt:
//! ```compile_fail
//! use kargu_core::application::budget::{Budget, BudgetLimits, DebitKind};
//! use kargu_core::domain::ExecutionTimeout;
//! fn cannot_reopen() -> Result<(), Box<dyn std::error::Error>> {
//! let budget = Budget::new(BudgetLimits::default(), ExecutionTimeout::UNLIMITED.start()?);
//! let mut sealed = budget.seal();
//! sealed.admit(DebitKind::NormalRequest);
//! Ok(())
//! }
//! ```
//!
//! A usage ticket cannot be collected twice:
//! ```compile_fail
//! use kargu_core::application::budget::{Budget, BudgetLimits, DebitKind, ObservedUsage};
//! use kargu_core::domain::ExecutionTimeout;
//! fn cannot_double_charge() -> Result<(), Box<dyn std::error::Error>> {
//! let mut budget = Budget::new(BudgetLimits::default(), ExecutionTimeout::UNLIMITED.start()?);
//! let charge = budget.admit(DebitKind::NormalRequest)?;
//! budget.finish(charge, ObservedUsage::default())?;
//! budget.finish(charge, ObservedUsage::default())?;
//! Ok(())
//! }
//! ```

mod domain;
use crate::{
    domain::{BudgetId, CompactionCount, Deadline, RequestCount, TokenCount},
    error::CoreError,
};
pub use domain::{
    BudgetLimits, CompactionLimit, DebitKind, ObservedUsage, RequestLimit, TokenLimit,
};
use serde::Serialize;
use std::{collections::BTreeSet, marker::PhantomData};

/// Ingress may be admitted while policy and accounting remain healthy.
pub struct Open;
/// Ingress is permanently revoked; outstanding usage still has to be collected.
pub struct Sealed;

/// Closed failure taxonomy; no decisions depend on upstream error text.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, thiserror::Error)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// No additional request fits.
    #[error("request budget exhausted")]
    Requests,
    /// Absolute run deadline elapsed.
    #[error("budget deadline exhausted")]
    Deadline,
    /// Another logical compaction is forbidden.
    #[error("compaction budget exhausted")]
    Compactions,
    /// Observed usage exhausted the configured ceiling.
    #[error("token budget exhausted")]
    Tokens,
    /// A token cap cannot be verified after an unknown/partial measurement.
    #[error("token usage unknown under a configured ceiling")]
    UnknownUsage,
    /// No hard reservation exists, so wait for the outstanding measurement.
    #[error("token measurement pending")]
    PendingUsage,
    /// Exact accounting failed; never wrap or reset it to zero.
    #[error("budget accounting overflow")]
    Accounting,
}

/// Move-only ticket. Completion consumes it once, including after cancellation.
#[must_use = "A charged attempt must be completed, including on cancellation"]
pub struct AttemptCharge {
    budget: BudgetId,
    sequence: RequestCount,
}

/// Immutable projection, not admission authority.
#[derive(Debug, Serialize)]
pub struct BudgetSnapshot {
    budget_id: BudgetId,
    limits: BudgetLimits,
    requests_spent: RequestCount,
    compactions_spent: CompactionCount,
    tokens_spent: TokenCount,
    tokens_unknown: bool,
    outstanding: usize,
    refusal: Option<Refusal>,
    sealed: bool,
}

/// Owner mutates this ledger; workers only return observations and their ticket.
pub struct Budget<State = Open> {
    id: BudgetId,
    limits: BudgetLimits,
    deadline: Deadline,
    requests: RequestCount,
    compactions: CompactionCount,
    tokens: TokenCount,
    unknown: bool,
    refusal: Option<Refusal>,
    outstanding: BTreeSet<RequestCount>,
    sealed: bool,
    state: PhantomData<State>,
}
impl Budget<Open> {
    /// Capture validated policy and the original monotonic deadline once.
    pub fn new(limits: BudgetLimits, deadline: Deadline) -> Self {
        Self {
            id: BudgetId::new(),
            limits,
            deadline,
            requests: RequestCount::ZERO,
            compactions: CompactionCount::ZERO,
            tokens: TokenCount::ZERO,
            unknown: false,
            refusal: None,
            outstanding: BTreeSet::new(),
            sealed: false,
            state: PhantomData,
        }
    }
    /// Charge one physical attempt before IO. Refusal never increments counters.
    pub fn admit(&mut self, kind: DebitKind) -> Result<AttemptCharge, Refusal> {
        if let Some(refusal) = self.refusal {
            return Err(refusal);
        }
        // Temporary contention must not poison an otherwise healthy meter.
        if self.limits.tokens().is_some() && !self.outstanding.is_empty() {
            return Err(Refusal::PendingUsage);
        }
        let refusal = if self.deadline.expired() {
            Some(Refusal::Deadline)
        } else if matches!(kind, DebitKind::CompactionTurn)
            && self.compactions.as_u64() >= self.limits.compactions().count()
        {
            Some(Refusal::Compactions)
        } else if self.requests.as_u64() >= self.limits.requests().count() {
            Some(Refusal::Requests)
        } else if let Some(limit) = self.limits.tokens() {
            if self.unknown {
                Some(Refusal::UnknownUsage)
            } else if self.tokens >= limit.count() {
                Some(Refusal::Tokens)
            } else {
                None
            }
        } else {
            None
        };
        if let Some(refusal) = refusal {
            self.refusal = Some(refusal);
            return Err(refusal);
        }
        // Compute the entire transition first. Neither counter may partially commit.
        let requests = self.requests.next().map_err(|_| Refusal::Accounting)?;
        let compactions = if matches!(kind, DebitKind::CompactionTurn) {
            self.compactions.next().map_err(|_| Refusal::Accounting)?
        } else {
            self.compactions
        };
        self.requests = requests;
        self.compactions = compactions;
        self.outstanding.insert(requests);
        Ok(AttemptCharge {
            budget: self.id.clone(),
            sequence: requests,
        })
    }
    /// Consume admission rights; finishing already charged work remains possible.
    pub fn seal(self) -> Budget<Sealed> {
        Budget {
            id: self.id,
            limits: self.limits,
            deadline: self.deadline,
            requests: self.requests,
            compactions: self.compactions,
            tokens: self.tokens,
            unknown: self.unknown,
            refusal: self.refusal,
            outstanding: self.outstanding,
            sealed: true,
            state: PhantomData,
        }
    }
}
impl<State> Budget<State> {
    /// Bind actor records to this non-reusable accounting identity.
    pub fn id(&self) -> &BudgetId {
        &self.id
    }
    /// Deadline to race against IO as well as checking before admission.
    pub fn deadline(&self) -> Deadline {
        self.deadline
    }
    /// Complete a charged attempt once. Faults/cancellation use unknown usage.
    pub fn finish(&mut self, charge: AttemptCharge, usage: ObservedUsage) -> Result<(), CoreError> {
        if charge.budget != self.id || !self.outstanding.remove(&charge.sequence) {
            return Err(CoreError::StaleOwner);
        }
        self.unknown |= usage.unknown();
        let total = usage
            .total()
            .and_then(|total| self.tokens.checked_add(total));
        match total {
            Ok(total) => {
                self.tokens = total;
                if self
                    .limits
                    .tokens()
                    .is_some_and(|limit| total > limit.count())
                    && self.refusal.is_none()
                {
                    self.refusal = Some(Refusal::Tokens);
                }
                Ok(())
            }
            Err(error) => {
                self.unknown = true;
                self.refusal = Some(Refusal::Accounting);
                Err(error)
            }
        }
    }
    /// Sealing is not evidence of collection; release only after this becomes true.
    pub fn drained(&self) -> bool {
        self.outstanding.is_empty()
    }
    /// Produce detached values for UI/accounting, never another mutable ledger.
    pub fn snapshot(&self) -> BudgetSnapshot {
        BudgetSnapshot {
            budget_id: self.id.clone(),
            limits: self.limits,
            requests_spent: self.requests,
            compactions_spent: self.compactions,
            tokens_spent: self.tokens,
            tokens_unknown: self.unknown,
            outstanding: self.outstanding.len(),
            refusal: self.refusal,
            sealed: self.sealed,
        }
    }
}
