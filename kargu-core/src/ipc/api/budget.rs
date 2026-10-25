//! Actor-owned accounting scopes. A budget identity never authorizes another owner.

use super::{Fault, RpcId, fault, protocol};
use crate::{
    application::{
        budget::{
            AttemptCharge, Budget, BudgetLimits, BudgetSnapshot, DebitKind, ObservedUsage, Refusal,
            Sealed,
        },
        host::{Host, ReadScope},
    },
    constants::{limits, protocol::methods},
    domain::{ApplicationId, BudgetId, Deadline, ExecutionTimeout},
    error::CoreError,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    time::{Duration, SystemTime},
};
use tokio::time::Instant;

#[derive(Deserialize)]
#[serde(try_from = "u64")]
struct BudgetDeadline(Deadline);
impl TryFrom<u64> for BudgetDeadline {
    type Error = CoreError;
    fn try_from(milliseconds: u64) -> Result<Self, CoreError> {
        // Sample monotonic first: conversion may shorten, never extend, the
        // original deadline while IPC/configuration startup consumes its time.
        let monotonic = Instant::now();
        let wall = SystemTime::now();
        let target = SystemTime::UNIX_EPOCH
            .checked_add(Duration::from_millis(milliseconds))
            .ok_or(CoreError::InvalidValue {
                field: "BudgetDeadline",
            })?;
        let remaining = target.duration_since(wall).unwrap_or(Duration::ZERO);
        Ok(Self(Deadline::at(monotonic.checked_add(remaining).ok_or(
            CoreError::InvalidValue {
                field: "BudgetDeadline",
            },
        )?)))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OpenRequest {
    scope: ReadScope,
    #[serde(default)]
    limits: BudgetLimits,
    #[serde(default)]
    deadline_epoch_ms: Option<BudgetDeadline>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OwnedRequest {
    scope: ReadScope,
    budget_id: BudgetId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct BudgetRef {
    pub budget_id: BudgetId,
    pub kind: DebitKind,
}
pub(super) struct Charge {
    pub id: BudgetId,
    pub ticket: AttemptCharge,
    pub deadline: Deadline,
}

/// Internal admission taxonomy. RPC strings exist only in the wire projection.
#[derive(Debug, thiserror::Error)]
pub(super) enum AdmissionFailure {
    #[error("application budget required")]
    Required,
    #[error("budget cannot meter a non-generative request")]
    NonGenerative,
    #[error("accounting owner is stale")]
    StaleOwner,
    #[error("budget admission revoked")]
    Closed,
    #[error("previous charged attempt is draining")]
    Busy,
    #[error(transparent)]
    Exhausted(#[from] Refusal),
}
impl From<AdmissionFailure> for Fault {
    fn from(value: AdmissionFailure) -> Self {
        match value {
            AdmissionFailure::Required => fault(
                "budget_required",
                "Application requests must share its captured budget",
            ),
            AdmissionFailure::NonGenerative => Self::params(),
            AdmissionFailure::StaleOwner => stale(),
            AdmissionFailure::Closed => fault("budget_closed", "Budget admission was revoked"),
            AdmissionFailure::Busy => {
                fault("budget_busy", "Previous charged attempt is still draining")
            }
            AdmissionFailure::Exhausted(_) => fault("budget_exhausted", "Run budget exhausted"),
        }
    }
}

enum Meter {
    Open(Budget),
    Sealed(Budget<Sealed>),
}
impl Meter {
    fn seal(self) -> Self {
        match self {
            Self::Open(budget) => Self::Sealed(budget.seal()),
            sealed => sealed,
        }
    }
    fn drained(&self) -> bool {
        match self {
            Self::Open(budget) => budget.drained(),
            Self::Sealed(budget) => budget.drained(),
        }
    }
    fn snapshot(&self) -> BudgetSnapshot {
        match self {
            Self::Open(budget) => budget.snapshot(),
            Self::Sealed(budget) => budget.snapshot(),
        }
    }
    fn finish(&mut self, charge: AttemptCharge, usage: ObservedUsage) -> Result<(), CoreError> {
        match self {
            Self::Open(budget) => budget.finish(charge, usage),
            Self::Sealed(budget) => budget.finish(charge, usage),
        }
    }
}
struct Closing {
    id: RpcId,
    publish: bool,
}
struct Owned {
    scope: ReadScope,
    meter: Meter,
    close: Option<Closing>,
}

#[derive(Default)]
pub(super) struct Budgets {
    entries: HashMap<BudgetId, Owned>,
}
impl Budgets {
    pub fn owns_application(&self, id: &ApplicationId) -> bool {
        self.entries
            .values()
            .any(|entry| &entry.scope.application_id == id)
    }
    pub fn contains(&self, id: &RpcId) -> bool {
        self.entries
            .values()
            .any(|entry| entry.close.as_ref().is_some_and(|close| &close.id == id))
    }
    pub fn closing(&self) -> bool {
        self.entries.values().any(|entry| entry.close.is_some())
    }
    pub fn revoked(&self, id: &BudgetId) -> bool {
        !self
            .entries
            .get(id)
            .is_some_and(|entry| matches!(entry.meter, Meter::Open(_)))
    }
    pub fn cancel_waiter(&mut self, id: &RpcId) {
        for entry in self.entries.values_mut() {
            if let Some(close) = &mut entry.close
                && &close.id == id
            {
                close.publish = false;
            }
        }
    }
    pub fn rpc(
        &mut self,
        host: &Host,
        method: &str,
        id: RpcId,
        params: Value,
        busy: impl Fn(&ApplicationId) -> bool,
    ) -> Result<Option<Value>, Fault> {
        if method == methods::API_BUDGET_OPEN {
            let request: OpenRequest =
                serde_json::from_value(params).map_err(|_| Fault::params())?;
            if !host.owns_read_scope(&request.scope) {
                return Err(fault("stale_owner", "Budget owner is no longer live"));
            }
            if self.entries.len() >= limits::MAX_APPLICATIONS
                || busy(&request.scope.application_id)
                || self
                    .entries
                    .values()
                    .any(|entry| entry.scope.application_id == request.scope.application_id)
            {
                return Err(fault(
                    "budget_busy",
                    "An application budget is already live or draining",
                ));
            }
            let deadline = match request.deadline_epoch_ms {
                Some(value) => value.0,
                None => ExecutionTimeout::UNLIMITED
                    .start()
                    .map_err(|_| Fault::params())?,
            };
            let budget = Budget::new(request.limits, deadline);
            let snapshot = json!(budget.snapshot());
            self.entries.insert(
                budget.id().clone(),
                Owned {
                    scope: request.scope,
                    meter: Meter::Open(budget),
                    close: None,
                },
            );
            return Ok(Some(snapshot));
        }
        let request: OwnedRequest = serde_json::from_value(params).map_err(|_| Fault::params())?;
        self.owner(host, &request.scope, &request.budget_id)?;
        if method == methods::API_BUDGET_SNAPSHOT {
            let entry = self.entries.get(&request.budget_id).ok_or_else(stale)?;
            return Ok(Some(json!(entry.meter.snapshot())));
        }
        if method != methods::API_BUDGET_CLOSE {
            return Err(Fault::params());
        }
        let entry = self.entries.remove(&request.budget_id).ok_or_else(stale)?;
        if entry.close.is_some() {
            self.entries.insert(request.budget_id, entry);
            return Err(fault("budget_closing", "Budget close already pending"));
        }
        self.entries.insert(
            request.budget_id,
            Owned {
                scope: entry.scope,
                meter: entry.meter.seal(),
                close: Some(Closing { id, publish: true }),
            },
        );
        Ok(None)
    }
    fn owner(&self, host: &Host, scope: &ReadScope, id: &BudgetId) -> Result<(), Fault> {
        self.admission_owner(host, scope, id).map_err(Into::into)
    }
    fn admission_owner(
        &self,
        host: &Host,
        scope: &ReadScope,
        id: &BudgetId,
    ) -> Result<(), AdmissionFailure> {
        if !host.owns_read_scope(scope)
            || !self
                .entries
                .get(id)
                .is_some_and(|entry| &entry.scope == scope)
        {
            return Err(AdmissionFailure::StaleOwner);
        }
        Ok(())
    }
    pub fn admit(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        reference: Option<&BudgetRef>,
        generative: bool,
    ) -> Result<Option<Charge>, AdmissionFailure> {
        let Some(reference) = reference else {
            if generative
                && self
                    .entries
                    .values()
                    .any(|entry| entry.scope.application_id == scope.application_id)
            {
                return Err(AdmissionFailure::Required);
            }
            return Ok(None);
        };
        if !generative {
            return Err(AdmissionFailure::NonGenerative);
        }
        self.admit_metered(host, scope, reference).map(Some)
    }
    pub fn admit_metered(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        reference: &BudgetRef,
    ) -> Result<Charge, AdmissionFailure> {
        let budget = self.open_meter(host, scope, &reference.budget_id)?;
        let charge = budget.admit(reference.kind)?;
        Ok(Charge {
            id: reference.budget_id.clone(),
            ticket: charge,
            deadline: budget.deadline(),
        })
    }
    fn open_meter(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        id: &BudgetId,
    ) -> Result<&mut Budget, AdmissionFailure> {
        self.admission_owner(host, scope, id)?;
        let entry = self
            .entries
            .get_mut(id)
            .ok_or(AdmissionFailure::StaleOwner)?;
        let Meter::Open(budget) = &mut entry.meter else {
            return Err(AdmissionFailure::Closed);
        };
        if !budget.drained() {
            return Err(AdmissionFailure::Busy);
        }
        Ok(budget)
    }
    pub fn preflight(
        &mut self,
        host: &Host,
        scope: &ReadScope,
        reference: &BudgetRef,
    ) -> Result<(), AdmissionFailure> {
        self.open_meter(host, scope, &reference.budget_id)?
            .preflight(reference.kind)?;
        Ok(())
    }
    pub fn snapshot(&self, id: &BudgetId) -> Option<Value> {
        self.entries
            .get(id)
            .map(|entry| json!(entry.meter.snapshot()))
    }
    pub fn finish(&mut self, charge: Charge, usage: ObservedUsage) -> Result<Value, CoreError> {
        let entry = self
            .entries
            .get_mut(&charge.id)
            .ok_or(CoreError::CleanupFailed)?;
        // Overflow is recorded terminally by the meter; the detached projection
        // still reports the last exact total and unknown flag to its owner.
        match entry.meter.finish(charge.ticket, usage) {
            Ok(()) | Err(CoreError::ArithmeticOverflow) => Ok(json!(entry.meter.snapshot())),
            Err(error) => Err(error),
        }
    }
    pub fn collect(&mut self, host: &Host, retained: impl Fn(&BudgetId) -> bool) -> Vec<Value> {
        let stale_ids: Vec<_> = self
            .entries
            .iter()
            .filter(|(_, entry)| !host.owns_read_scope(&entry.scope))
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale_ids {
            if let Some(entry) = self.entries.remove(&id) {
                self.entries.insert(
                    id,
                    Owned {
                        scope: entry.scope,
                        meter: entry.meter.seal(),
                        close: entry.close,
                    },
                );
            }
        }
        let drained: Vec<_> = self
            .entries
            .iter()
            .filter(|(id, entry)| {
                matches!(entry.meter, Meter::Sealed(_)) && entry.meter.drained() && !retained(id)
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut replies = Vec::new();
        for id in drained {
            if let Some(entry) = self.entries.remove(&id)
                && let Some(close) = entry.close
                && close.publish
            {
                replies.push(protocol::success(
                    &close.id,
                    json!({"status":"closed", "budget":entry.meter.snapshot()}),
                ));
            }
        }
        replies
    }
}
fn stale() -> Fault {
    fault(
        "stale_owner",
        "Budget belongs to another or closed accounting lifetime",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn host() -> Result<(Host, Value, ReadScope), Box<dyn std::error::Error>> {
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"budget-test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result?;
        host.dispatch("initialized", json!({}), false).result?;
        let application = host
            .dispatch("application/create", json!({}), true)
            .result?;
        let scope = host.dispatch("session/create", application, true).result?;
        let typed = serde_json::from_value(scope.clone())?;
        Ok((host, scope, typed))
    }
    #[test]
    fn close_waiter_cancellation_neither_reopens_nor_releases_a_charged_budget() -> TestResult {
        let (host, scope, typed) = host()?;
        let mut budgets = Budgets::default();
        let opened = budgets
            .rpc(
                &host,
                methods::API_BUDGET_OPEN,
                RpcId::Integer(1),
                json!({"scope":scope}),
                |_| false,
            )?
            .ok_or("open result")?;
        let budget_id: BudgetId = serde_json::from_value(opened["budget_id"].clone())?;
        let reference = BudgetRef {
            budget_id: budget_id.clone(),
            kind: DebitKind::NormalRequest,
        };
        let charge = budgets
            .admit(&host, &typed, Some(&reference), true)?
            .ok_or("charge")?;
        budgets.rpc(
            &host,
            methods::API_BUDGET_CLOSE,
            RpcId::Integer(2),
            json!({"scope":scope,"budget_id":budget_id}),
            |_| false,
        )?;
        budgets.cancel_waiter(&RpcId::Integer(2));
        assert!(budgets.contains(&RpcId::Integer(2)));
        assert!(budgets.collect(&host, |_| false).is_empty());
        assert!(budgets.revoked(&budget_id));
        assert!(
            budgets
                .admit(&host, &typed, Some(&reference), true)
                .is_err()
        );
        assert!(
            budgets
                .rpc(
                    &host,
                    methods::API_BUDGET_OPEN,
                    RpcId::Integer(3),
                    json!({"scope":scope}),
                    |_| false
                )
                .is_err()
        );
        budgets.finish(charge, ObservedUsage::default())?;
        assert!(budgets.collect(&host, |_| false).is_empty());
        assert!(!budgets.contains(&RpcId::Integer(2)));
        assert!(budgets.entries.is_empty());
        let next = budgets
            .rpc(
                &host,
                methods::API_BUDGET_OPEN,
                RpcId::Integer(4),
                json!({"scope":scope}),
                |_| false,
            )?
            .ok_or("new result")?;
        assert_ne!(opened["budget_id"], next["budget_id"]);
        assert!(
            budgets
                .admit(&host, &typed, Some(&reference), true)
                .is_err()
        );
        Ok(())
    }
    #[test]
    fn zero_outstanding_charges_do_not_release_a_retained_logical_operation() -> TestResult {
        let (host, scope, typed) = host()?;
        let mut budgets = Budgets::default();
        let opened = budgets
            .rpc(
                &host,
                methods::API_BUDGET_OPEN,
                RpcId::Integer(1),
                json!({"scope":scope}),
                |_| false,
            )?
            .ok_or("open")?;
        let budget_id: BudgetId = serde_json::from_value(opened["budget_id"].clone())?;
        let reference = BudgetRef {
            budget_id: budget_id.clone(),
            kind: DebitKind::NormalRequest,
        };
        let charge = budgets
            .admit(&host, &typed, Some(&reference), true)?
            .ok_or("charge")?;
        budgets.finish(charge, ObservedUsage::default())?;
        budgets.rpc(
            &host,
            methods::API_BUDGET_CLOSE,
            RpcId::Integer(2),
            json!({"scope":scope,"budget_id":budget_id}),
            |_| false,
        )?;
        assert!(budgets.collect(&host, |id| id == &budget_id).is_empty());
        assert!(budgets.contains(&RpcId::Integer(2)));
        assert!(budgets.revoked(&budget_id));
        assert!(matches!(
            budgets.admit(&host, &typed, Some(&reference), true),
            Err(AdmissionFailure::Closed)
        ));
        let replies = budgets.collect(&host, |_| false);
        assert_eq!(replies.len(), 1);
        assert_eq!(
            replies.first().ok_or("close")?["result"]["status"],
            "closed"
        );
        assert!(budgets.entries.is_empty());
        assert!(budgets.collect(&host, |_| false).is_empty());
        Ok(())
    }
    #[test]
    fn existing_unmetered_attempt_prevents_late_budget_creation() -> TestResult {
        let (host, scope, _) = host()?;
        let mut budgets = Budgets::default();
        let result = budgets.rpc(
            &host,
            methods::API_BUDGET_OPEN,
            RpcId::Integer(1),
            json!({"scope":scope}),
            |_| true,
        );
        assert!(matches!(
            result,
            Err(Fault {
                status: "budget_busy",
                ..
            })
        ));
        assert!(budgets.entries.is_empty());
        Ok(())
    }
}
