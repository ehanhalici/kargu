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
mod pricing;
use crate::{
    domain::{BudgetId, CompactionCount, Deadline, MicroUsd, RequestCount, TokenCount},
    error::CoreError,
};
pub use domain::{
    AttemptBounds, BudgetLimits, CompactionLimit, DebitKind, MonetaryLimit, ObservedUsage,
    RequestLimit, TokenLimit,
};
pub use pricing::{PricingRates, PricingUsage};
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    marker::PhantomData,
};

/// Ingress may be admitted while policy and accounting remain healthy.
pub struct Open;
/// Ingress is permanently revoked; outstanding usage still has to be collected.
pub struct Sealed;

pub use crate::error::Refusal;

/// Move-only ticket. Completion consumes it once, including after cancellation.
#[must_use = "A charged attempt must be completed, including on cancellation"]
pub struct AttemptCharge {
    budget: BudgetId,
    sequence: RequestCount,
    reserved: MicroUsd,
}

impl AttemptCharge {
    /// Bound budget identity.
    pub fn budget(&self) -> &BudgetId {
        &self.budget
    }
    /// Monotonic attempt sequence.
    pub fn sequence(&self) -> RequestCount {
        self.sequence
    }
    /// Reserved micro-dollars for this attempt.
    pub fn reserved(&self) -> MicroUsd {
        self.reserved
    }
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
    monetary_spent: MicroUsd,
    monetary_reserved: MicroUsd,
    monetary_unknown: bool,
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
    monetary: MicroUsd,
    reserved_monetary: MicroUsd,
    monetary_unknown: bool,
    refusal: Option<Refusal>,
    outstanding: BTreeSet<RequestCount>,
    reservations: BTreeMap<RequestCount, MicroUsd>,
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
            monetary: MicroUsd::ZERO,
            reserved_monetary: MicroUsd::ZERO,
            monetary_unknown: false,
            refusal: None,
            outstanding: BTreeSet::new(),
            reservations: BTreeMap::new(),
            sealed: false,
            state: PhantomData,
        }
    }
    /// Check the next attempt without charging it or reserving future admission.
    /// The actor must call `admit` again after backoff/observer handoff.
    pub fn preflight(&mut self, kind: DebitKind) -> Result<(), Refusal> {
        if let Some(refusal) = self.refusal {
            return Err(refusal);
        }
        // Temporary contention must not poison an otherwise healthy meter.
        if (self.limits.tokens().is_some() || self.limits.monetary().is_some())
            && !self.outstanding.is_empty()
        {
            return Err(Refusal::PendingUsage);
        }
        self.check_common_limits(kind)?;
        if self.limits.monetary().is_some() && self.monetary_unknown {
            self.refusal = Some(Refusal::UnknownPricing);
            return Err(Refusal::UnknownPricing);
        }
        if self
            .limits
            .monetary()
            .is_some_and(|limit| self.monetary.as_u64() >= limit.amount().as_u64())
        {
            self.refusal = Some(Refusal::Monetary);
            return Err(Refusal::Monetary);
        }
        Ok(())
    }
    fn check_common_limits(&mut self, kind: DebitKind) -> Result<(), Refusal> {
        let refusal = if self.deadline.expired() {
            Some(Refusal::Deadline)
        } else if matches!(kind, DebitKind::CompactionTurn)
            && self.compactions.as_u64() >= self.limits.compactions().count()
        {
            Some(Refusal::Compactions)
        } else if self.requests.as_u64() >= self.limits.requests().count() {
            Some(Refusal::Requests)
        } else if self.limits.tokens().is_some() && self.unknown {
            Some(Refusal::UnknownUsage)
        } else if self
            .limits
            .tokens()
            .is_some_and(|limit| self.tokens >= limit.count())
        {
            Some(Refusal::Tokens)
        } else {
            None
        };
        if let Some(refusal) = refusal {
            self.refusal = Some(refusal);
            return Err(refusal);
        }
        Ok(())
    }
    /// Check admission and calculate worst-case fixed-point reservation.
    pub fn preflight_reservation(
        &mut self,
        kind: DebitKind,
        rates: Option<&PricingRates>,
        bounds: Option<&AttemptBounds>,
    ) -> Result<MicroUsd, Refusal> {
        if let Some(refusal) = self.refusal {
            return Err(refusal);
        }
        self.check_common_limits(kind)?;
        self.check_monetary_reservation(rates, bounds)
    }
    fn check_monetary_reservation(
        &mut self,
        rates: Option<&PricingRates>,
        bounds: Option<&AttemptBounds>,
    ) -> Result<MicroUsd, Refusal> {
        let Some(limit) = self.limits.monetary() else {
            if self.limits.tokens().is_some() && !self.outstanding.is_empty() {
                return Err(Refusal::PendingUsage);
            }
            return Ok(MicroUsd::ZERO);
        };
        if self.monetary_unknown {
            self.refusal = Some(Refusal::UnknownPricing);
            return Err(Refusal::UnknownPricing);
        }
        if self.monetary.as_u64() >= limit.amount().as_u64() {
            self.refusal = Some(Refusal::Monetary);
            return Err(Refusal::Monetary);
        }
        let rates = rates.ok_or(Refusal::UnknownPricing)?;
        let bounds = bounds.ok_or(Refusal::UnboundedOutput)?;
        let reservation = rates.compute_reservation(bounds)?;
        let committed = self
            .monetary
            .checked_add(self.reserved_monetary)
            .map_err(|_| Refusal::Accounting)?;
        let needed = committed
            .checked_add(reservation)
            .map_err(|_| Refusal::Accounting)?;
        if needed.as_u64() > limit.amount().as_u64() {
            return Err(Refusal::Monetary);
        }
        Ok(reservation)
    }
    /// Charge one physical attempt before IO. Refusal never increments counters.
    pub fn admit(&mut self, kind: DebitKind) -> Result<AttemptCharge, Refusal> {
        self.preflight(kind)?;
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
            reserved: MicroUsd::ZERO,
        })
    }
    /// Admit one attempt with worst-case reservation.
    pub fn admit_reservation(
        &mut self,
        kind: DebitKind,
        rates: Option<&PricingRates>,
        bounds: Option<&AttemptBounds>,
    ) -> Result<AttemptCharge, Refusal> {
        let reservation = self.preflight_reservation(kind, rates, bounds)?;
        let requests = self.requests.next().map_err(|_| Refusal::Accounting)?;
        let compactions = if matches!(kind, DebitKind::CompactionTurn) {
            self.compactions.next().map_err(|_| Refusal::Accounting)?
        } else {
            self.compactions
        };
        let reserved_monetary = self
            .reserved_monetary
            .checked_add(reservation)
            .map_err(|_| Refusal::Accounting)?;
        self.requests = requests;
        self.compactions = compactions;
        self.reserved_monetary = reserved_monetary;
        self.outstanding.insert(requests);
        self.reservations.insert(requests, reservation);
        Ok(AttemptCharge {
            budget: self.id.clone(),
            sequence: requests,
            reserved: reservation,
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
            monetary: self.monetary,
            reserved_monetary: self.reserved_monetary,
            monetary_unknown: self.monetary_unknown,
            refusal: self.refusal,
            outstanding: self.outstanding,
            reservations: self.reservations,
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
    /// Reserved monetary spend currently in-flight across active attempts.
    pub fn reserved_monetary(&self) -> MicroUsd {
        self.reserved_monetary
    }
    /// Complete a charged attempt once. Faults/cancellation use unknown usage.
    pub fn finish(&mut self, charge: AttemptCharge, usage: ObservedUsage) -> Result<(), CoreError> {
        self.finish_with_cost(charge, usage, None)
    }
    /// Complete a charged attempt with optional exact monetary cost.
    pub fn finish_with_cost(
        &mut self,
        charge: AttemptCharge,
        usage: ObservedUsage,
        cost: Option<MicroUsd>,
    ) -> Result<(), CoreError> {
        if charge.budget != self.id || !self.outstanding.remove(&charge.sequence) {
            return Err(CoreError::StaleOwner);
        }
        self.release_reservation(&charge);
        if self.deadline.expired() && self.refusal.is_none() {
            self.refusal = Some(Refusal::Deadline);
        }
        self.unknown |= usage.unknown();
        let next_monetary = self.check_monetary_transition(usage, cost)?;
        let next_tokens = self.check_token_transition(usage)?;
        self.commit_transitions(next_monetary, next_tokens);
        Ok(())
    }
    fn release_reservation(&mut self, charge: &AttemptCharge) {
        let reserved = match self.reservations.remove(&charge.sequence) {
            Some(amount) => amount,
            None => charge.reserved,
        };
        let remaining = self
            .reserved_monetary
            .as_u64()
            .checked_sub(reserved.as_u64())
            .and_then(|rem| MicroUsd::try_from(rem).ok());
        if let Some(micro) = remaining {
            self.reserved_monetary = micro;
        }
    }
    fn check_monetary_transition(
        &mut self,
        usage: ObservedUsage,
        cost: Option<MicroUsd>,
    ) -> Result<Option<MicroUsd>, CoreError> {
        match cost {
            Some(micro) => self.monetary.checked_add(micro).map(Some).inspect_err(|_| {
                self.monetary_unknown = true;
                self.refusal = Some(Refusal::Accounting);
            }),
            None => {
                if usage.unknown() || usage.total().is_ok_and(|t| t > TokenCount::ZERO) {
                    self.monetary_unknown = true;
                }
                Ok(None)
            }
        }
    }
    fn check_token_transition(&mut self, usage: ObservedUsage) -> Result<TokenCount, CoreError> {
        let attempt_tokens = usage.total().inspect_err(|_| {
            self.unknown = true;
            self.refusal = Some(Refusal::Accounting);
        })?;
        self.tokens.checked_add(attempt_tokens).inspect_err(|_| {
            self.unknown = true;
            self.refusal = Some(Refusal::Accounting);
        })
    }
    fn commit_transitions(&mut self, next_monetary: Option<MicroUsd>, next_tokens: TokenCount) {
        if let Some(sum) = next_monetary {
            self.monetary = sum;
            if self
                .limits
                .monetary()
                .is_some_and(|limit| sum.as_u64() >= limit.amount().as_u64())
                && self.refusal.is_none()
            {
                self.refusal = Some(Refusal::Monetary);
            }
        }
        self.tokens = next_tokens;
        if self
            .limits
            .tokens()
            .is_some_and(|limit| next_tokens > limit.count())
            && self.refusal.is_none()
        {
            self.refusal = Some(Refusal::Tokens);
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
            monetary_spent: self.monetary,
            monetary_reserved: self.reserved_monetary,
            monetary_unknown: self.monetary_unknown,
            outstanding: self.outstanding.len(),
            refusal: self.refusal,
            sealed: self.sealed,
        }
    }
}
