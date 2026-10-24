//! Native budget contracts replace policy tests only after editor cutover.

use kargu_core::{
    application::budget::{Budget, BudgetLimits, DebitKind, ObservedUsage, Refusal},
    domain::{ExecutionTimeout, InputTokens, OutputTokens},
};
use serde_json::{Value, json};
use std::time::Duration;

type TestResult = Result<(), Box<dyn std::error::Error>>;
fn budget(limits: Value) -> Result<Budget, Box<dyn std::error::Error>> {
    Ok(Budget::new(
        serde_json::from_value(limits)?,
        ExecutionTimeout::UNLIMITED.start()?,
    ))
}
fn snapshot<State>(budget: &Budget<State>) -> Result<Value, serde_json::Error> {
    serde_json::to_value(budget.snapshot())
}
fn known(input: u64, output: u64) -> Result<ObservedUsage, Box<dyn std::error::Error>> {
    Ok(ObservedUsage::new(
        Some(InputTokens::try_from(input)?),
        Some(OutputTokens::try_from(output)?),
    ))
}

#[test]
fn limits_parse_once_and_defaults_are_bounded() -> TestResult {
    let value = serde_json::to_value(BudgetLimits::default())?;
    assert_eq!(value, json!({"requests":30,"compactions":1,"tokens":null}));
    for invalid in [
        json!({"requests":0}),
        json!({"requests":10_001}),
        json!({"requests":-1}),
        json!({"requests":1.5}),
        json!({"compactions":-1}),
        json!({"compactions":10_001}),
        json!({"tokens":0}),
        json!({"tokens":1.5}),
        json!({"other":1}),
    ] {
        assert!(serde_json::from_value::<BudgetLimits>(invalid).is_err());
    }
    assert!(
        serde_json::from_value::<BudgetLimits>(
            json!({"requests":10_000,"compactions":0,"tokens":u64::MAX})
        )
        .is_ok()
    );
    Ok(())
}

#[test]
fn all_attempt_kinds_share_one_irreversible_gate() -> TestResult {
    let mut budget = budget(json!({"requests":5}))?;
    for kind in [
        DebitKind::NormalRequest,
        DebitKind::RetryAttempt,
        DebitKind::HealingTurn,
        DebitKind::Continuation,
        DebitKind::CompactionTurn,
    ] {
        let charge = budget.admit(kind)?;
        budget.finish(charge, known(1, 2)?)?;
    }
    assert!(matches!(
        budget.admit(DebitKind::NormalRequest),
        Err(Refusal::Requests)
    ));
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::Requests)
    ));
    let state = snapshot(&budget)?;
    assert_eq!(state["requests_spent"], 5);
    assert_eq!(state["compactions_spent"], 1);
    assert_eq!(state["tokens_spent"], 15);
    assert_eq!(state["outstanding"], 0);
    Ok(())
}

#[test]
fn retrying_a_compaction_does_not_admit_a_second_logical_compaction() -> TestResult {
    let mut budget = budget(json!({}))?;
    let first = budget.admit(DebitKind::CompactionTurn)?;
    budget.finish(first, ObservedUsage::default())?;
    let retry = budget.admit(DebitKind::RetryAttempt)?;
    budget.finish(retry, known(3, 0)?)?;
    assert!(matches!(
        budget.admit(DebitKind::CompactionTurn),
        Err(Refusal::Compactions)
    ));
    let state = snapshot(&budget)?;
    assert_eq!(state["requests_spent"], 2);
    assert_eq!(state["compactions_spent"], 1);
    assert_eq!(state["tokens_unknown"], true);
    Ok(())
}

#[test]
fn zero_compactions_means_forbidden_not_default_one() -> TestResult {
    let mut budget = budget(json!({"compactions":0}))?;
    assert!(matches!(
        budget.admit(DebitKind::CompactionTurn),
        Err(Refusal::Compactions)
    ));
    assert_eq!(snapshot(&budget)?["requests_spent"], 0);
    Ok(())
}

#[test]
fn pending_measurement_refuses_overlap_without_poisoning_the_budget() -> TestResult {
    let mut budget = budget(json!({"tokens":100}))?;
    let charge = budget.admit(DebitKind::NormalRequest)?;
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::PendingUsage)
    ));
    assert!(snapshot(&budget)?["refusal"].is_null());
    budget.finish(charge, known(1, 1)?)?;
    let charge = budget.admit(DebitKind::RetryAttempt)?;
    budget.finish(charge, known(1, 1)?)?;
    assert_eq!(snapshot(&budget)?["requests_spent"], 2);
    Ok(())
}

#[test]
fn foreign_ticket_cannot_debit_or_complete_a_different_meter() -> TestResult {
    let mut first = budget(json!({}))?;
    let mut second = budget(json!({}))?;
    let charge = first.admit(DebitKind::NormalRequest)?;
    let before = snapshot(&second)?;
    assert!(second.finish(charge, known(10, 10)?).is_err());
    assert_eq!(snapshot(&second)?, before);
    assert!(!first.drained());
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn original_monotonic_deadline_is_not_extended_by_attempts() -> TestResult {
    let timeout = ExecutionTimeout::try_from(Duration::from_millis(10))?;
    let mut budget = Budget::new(BudgetLimits::default(), timeout.start()?);
    let first = budget.admit(DebitKind::NormalRequest)?;
    tokio::time::advance(Duration::from_millis(10)).await;
    budget.finish(first, known(0, 0)?)?;
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::Deadline)
    ));
    assert_eq!(snapshot(&budget)?["requests_spent"], 1);
    assert!(budget.deadline().expired());
    Ok(())
}

#[test]
fn usage_absence_partial_and_zero_remain_distinct() -> TestResult {
    let mut budget = budget(json!({}))?;
    for (usage, expected, unknown) in [
        (json!({"prompt_tokens":0,"completion_tokens":0}), 0, false),
        (json!({"prompt_tokens":9}), 9, true),
        (Value::Null, 9, true),
        (
            json!({"prompt_tokens":2,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":99},"completion_tokens_details":{"reasoning_tokens":99}}),
            14,
            true,
        ),
    ] {
        let charge = budget.admit(DebitKind::NormalRequest)?;
        budget.finish(charge, ObservedUsage::try_from(&json!({"usage":usage}))?)?;
        let state = snapshot(&budget)?;
        assert_eq!(state["tokens_spent"], expected);
        assert_eq!(state["tokens_unknown"], unknown);
    }
    Ok(())
}

#[test]
fn invalid_provider_usage_never_becomes_zero() {
    for invalid in [
        json!({"usage":false}),
        json!({"usage":[]}),
        json!({"usage":{"prompt_tokens":-1}}),
        json!({"usage":{"prompt_tokens":0.5}}),
        json!({"usage":{"completion_tokens":"1"}}),
    ] {
        assert!(ObservedUsage::try_from(&invalid).is_err());
    }
}

#[test]
fn unknown_usage_under_token_cap_fails_closed_without_free_retry() -> TestResult {
    let mut budget = budget(json!({"tokens":100}))?;
    let charge = budget.admit(DebitKind::NormalRequest)?;
    budget.finish(charge, ObservedUsage::default())?;
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::UnknownUsage)
    ));
    let state = snapshot(&budget)?;
    assert_eq!(state["requests_spent"], 1);
    assert_eq!(state["tokens_spent"], 0);
    assert_eq!(state["tokens_unknown"], true);
    Ok(())
}

#[test]
fn exact_token_ceiling_and_observed_overrun_do_not_claim_reservation() -> TestResult {
    let mut exact = budget(json!({"tokens":5}))?;
    let charge = exact.admit(DebitKind::NormalRequest)?;
    exact.finish(charge, known(3, 2)?)?;
    assert!(matches!(
        exact.admit(DebitKind::RetryAttempt),
        Err(Refusal::Tokens)
    ));
    let mut overrun = budget(json!({"tokens":5}))?;
    let charge = overrun.admit(DebitKind::NormalRequest)?;
    overrun.finish(charge, known(3, 3)?)?;
    assert_eq!(snapshot(&overrun)?["tokens_spent"], 6);
    assert_eq!(snapshot(&overrun)?["refusal"], "tokens");
    Ok(())
}

#[test]
fn seal_revokes_ingress_but_preserves_outstanding_charge_until_collection() -> TestResult {
    let mut budget = budget(json!({}))?;
    let first = budget.admit(DebitKind::NormalRequest)?;
    let second = budget.admit(DebitKind::RetryAttempt)?;
    let mut sealed = budget.seal();
    assert!(!sealed.drained());
    assert_eq!(snapshot(&sealed)?["sealed"], true);
    sealed.finish(first, known(4, 1)?)?;
    assert!(!sealed.drained());
    sealed.finish(second, ObservedUsage::default())?;
    assert!(sealed.drained());
    let state = snapshot(&sealed)?;
    assert_eq!(state["requests_spent"], 2);
    assert_eq!(state["tokens_spent"], 5);
    assert_eq!(state["tokens_unknown"], true);
    Ok(())
}

#[test]
fn exact_accounting_overflow_is_terminal_without_wrap_or_partial_commit() -> TestResult {
    let mut within = budget(json!({}))?;
    let charge = within.admit(DebitKind::NormalRequest)?;
    assert!(within.finish(charge, known(u64::MAX, 1)?).is_err());
    assert_eq!(snapshot(&within)?["tokens_spent"], 0);
    assert!(within.drained());
    assert!(matches!(
        within.admit(DebitKind::NormalRequest),
        Err(Refusal::Accounting)
    ));
    let mut across = budget(json!({}))?;
    let charge = across.admit(DebitKind::NormalRequest)?;
    across.finish(charge, known(u64::MAX, 0)?)?;
    let charge = across.admit(DebitKind::RetryAttempt)?;
    assert!(across.finish(charge, known(1, 0)?).is_err());
    assert_eq!(snapshot(&across)?["tokens_spent"], u64::MAX);
    assert_eq!(snapshot(&across)?["refusal"], "accounting");
    Ok(())
}
