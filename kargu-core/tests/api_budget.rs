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
fn preflight_neither_debits_nor_reserves_and_admission_rechecks() -> TestResult {
    let mut budget = budget(json!({"requests":1,"compactions":1}))?;
    let before = snapshot(&budget)?;
    for _ in 0..3 {
        budget.preflight(DebitKind::CompactionTurn)?;
    }
    assert_eq!(snapshot(&budget)?, before);
    let charge = budget.admit(DebitKind::NormalRequest)?;
    budget.finish(charge, known(1, 1)?)?;
    assert_eq!(
        budget.preflight(DebitKind::RetryAttempt),
        Err(Refusal::Requests)
    );
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::Requests)
    ));
    assert_eq!(snapshot(&budget)?["requests_spent"], 1);
    assert_eq!(snapshot(&budget)?["compactions_spent"], 0);
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn preflight_expiry_is_terminal_without_inventing_an_attempt() -> TestResult {
    let timeout = ExecutionTimeout::try_from(Duration::from_millis(10))?;
    let mut budget = Budget::new(BudgetLimits::default(), timeout.start()?);
    budget.preflight(DebitKind::RetryAttempt)?;
    tokio::time::advance(Duration::from_millis(10)).await;
    assert_eq!(
        budget.preflight(DebitKind::RetryAttempt),
        Err(Refusal::Deadline)
    );
    assert!(matches!(
        budget.admit(DebitKind::RetryAttempt),
        Err(Refusal::Deadline)
    ));
    assert_eq!(snapshot(&budget)?["requests_spent"], 0);
    assert_eq!(snapshot(&budget)?["refusal"], "deadline");
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

#[test]
fn compaction_and_healing_turns_share_single_run_limits() -> TestResult {
    let mut b = budget(json!({"requests": 4, "compactions": 1, "tokens": 100}))?;
    let first = b.admit(DebitKind::CompactionTurn)?;
    b.finish(first, known(10, 5)?)?;
    assert_eq!(snapshot(&b)?["compactions_spent"], 1);
    assert_eq!(snapshot(&b)?["requests_spent"], 1);
    assert_eq!(snapshot(&b)?["tokens_spent"], 15);

    // Healing turn uses the same run budget.
    let healing = b.admit(DebitKind::HealingTurn)?;
    b.finish(healing, known(10, 5)?)?;
    assert_eq!(snapshot(&b)?["requests_spent"], 2);
    assert_eq!(snapshot(&b)?["tokens_spent"], 30);

    // Continuation turn uses the same run budget.
    let cont = b.admit(DebitKind::Continuation)?;
    b.finish(cont, known(5, 5)?)?;
    assert_eq!(snapshot(&b)?["requests_spent"], 3);
    assert_eq!(snapshot(&b)?["tokens_spent"], 40);

    // Second logical compaction is refused under single compaction limit, locking the meter.
    assert!(matches!(
        b.admit(DebitKind::CompactionTurn),
        Err(Refusal::Compactions)
    ));
    assert_eq!(snapshot(&b)?["refusal"], "compactions");
    Ok(())
}

#[test]
fn monetary_microusd_and_rates_never_use_floats_and_fail_closed_on_overflow() -> TestResult {
    use kargu_core::domain::MicroUsd;
    use kargu_core::models::InputTokenRate;
    use std::str::FromStr;

    let zero_rate = InputTokenRate::from_str("0.00")?;
    assert!(zero_rate.is_zero());
    assert_eq!(zero_rate.per_million_label(), "$0.00/1M");

    let rate = InputTokenRate::from_str("0.0000015")?;
    assert!(!rate.is_zero());
    assert_eq!(rate.per_million_label(), "$1.50/1M");

    let micro = MicroUsd::try_from(1_000_000)?;
    assert_eq!(micro.as_u64(), 1_000_000);
    let overflow = MicroUsd::try_from(u64::MAX)?.checked_add(MicroUsd::try_from(1)?);
    assert!(overflow.is_err());
    Ok(())
}

#[test]
fn observed_monetary_ceiling_and_unknown_pricing_fail_closed() -> TestResult {
    use kargu_core::domain::MicroUsd;

    // A budget with an observed monetary ceiling of 2,000,000 MicroUsd ($2.00)
    let mut b = budget(json!({"requests": 5, "monetary": 2_000_000}))?;
    let charge = b.admit(DebitKind::NormalRequest)?;

    // Charge 1,500,000 MicroUsd
    b.finish_with_cost(
        charge,
        known(100, 50)?,
        Some(MicroUsd::try_from(1_500_000)?),
    )?;
    let state = snapshot(&b)?;
    assert_eq!(state["monetary_spent"], 1_500_000);
    assert_eq!(state["monetary_unknown"], false);

    // Second request fits under the $2.00 limit
    let charge2 = b.admit(DebitKind::NormalRequest)?;
    b.finish_with_cost(charge2, known(50, 25)?, Some(MicroUsd::try_from(600_000)?))?;

    // Now total is 2,100,000 MicroUsd, which exceeds 2,000,000 limit -> Refusal::Monetary
    assert!(matches!(
        b.admit(DebitKind::NormalRequest),
        Err(Refusal::Monetary)
    ));
    assert_eq!(snapshot(&b)?["refusal"], "monetary");

    // Test unknown pricing fails closed when monetary limit is set
    let mut unk = budget(json!({"requests": 5, "monetary": 5_000_000}))?;
    let charge = unk.admit(DebitKind::NormalRequest)?;
    // Finish with unknown cost (None) and non-zero tokens
    unk.finish_with_cost(charge, known(10, 10)?, None)?;
    assert_eq!(snapshot(&unk)?["monetary_unknown"], true);

    // Subsequent admission must fail closed with Refusal::UnknownPricing
    assert!(matches!(
        unk.admit(DebitKind::NormalRequest),
        Err(Refusal::UnknownPricing)
    ));
    assert_eq!(snapshot(&unk)?["refusal"], "unknown_pricing");
    Ok(())
}

#[test]
fn pricing_rates_calculates_exact_microusd_without_floats() -> TestResult {
    use kargu_core::application::budget::PricingRates;
    use kargu_core::domain::{InputTokens, OutputTokens};
    use kargu_core::models::{CacheReadTokenRate, InputTokenRate, OutputTokenRate};
    use std::str::FromStr;

    let input_rate = InputTokenRate::from_str("0.0000015")?; // $1.50 / 1M tokens
    let output_rate = OutputTokenRate::from_str("0.0000030")?; // $3.00 / 1M tokens
    let cache_rate = CacheReadTokenRate::from_str("0.0000005")?; // $0.50 / 1M tokens

    let pricing = PricingRates::new(Some(input_rate), Some(output_rate), Some(cache_rate));

    let cost = pricing.compute_cost(
        Some(InputTokens::try_from(1_000_000)?),
        Some(OutputTokens::try_from(500_000)?),
        Some(2_000_000),
    )?;

    // 1M * 1.50 = $1.50 = 1,500,000 MicroUsd
    // 500k * 3.00 = $1.50 = 1,500,000 MicroUsd
    // 2M * 0.50 = $1.00 = 1,000,000 MicroUsd
    // Total = 4,000,000 MicroUsd
    assert_eq!(cost.map(|c| c.as_u64()), Some(4_000_000));

    // Missing rate for non-zero tokens yields None (unknown)
    let partial = PricingRates::new(None, None, None);
    let unknown_cost = partial.compute_cost(Some(InputTokens::try_from(100)?), None, None)?;
    assert!(unknown_cost.is_none());
    Ok(())
}

#[test]
fn late_usage_and_monetary_charges_settle_after_seal() -> TestResult {
    use kargu_core::domain::MicroUsd;

    let mut b = budget(json!({"requests": 3, "monetary": 1_000_000}))?;
    let charge = b.admit(DebitKind::NormalRequest)?;

    let mut sealed = b.seal();
    assert!(!sealed.drained());

    // Deliver late result
    sealed.finish_with_cost(charge, known(50, 50)?, Some(MicroUsd::try_from(500_000)?))?;
    assert!(sealed.drained());
    let snap = snapshot(&sealed)?;
    assert_eq!(snap["monetary_spent"], 500_000);
    assert_eq!(snap["tokens_spent"], 100);
    assert_eq!(snap["sealed"], true);
    Ok(())
}

#[test]
fn token_ceiling_does_not_mask_unknown_monetary_usage() -> TestResult {
    let mut meter = budget(json!({"requests":10,"tokens":1000,"monetary":100}))?;
    let charge = meter.admit(DebitKind::NormalRequest)?;
    meter.finish(charge, known(1, 1)?)?;
    assert_eq!(
        meter.preflight(DebitKind::NormalRequest),
        Err(Refusal::UnknownPricing)
    );
    assert_eq!(snapshot(&meter)?["requests_spent"], 1);
    Ok(())
}

#[test]
fn incomplete_usage_and_fractional_microdollars_are_not_exact_zero() -> TestResult {
    use kargu_core::{application::budget::PricingRates, models::InputTokenRate};
    use std::str::FromStr;
    let pricing = PricingRates::new(Some(InputTokenRate::from_str("0.0000005")?), None, None);
    assert!(
        pricing
            .compute_cost(None, Some(OutputTokens::try_from(0)?), None)?
            .is_none()
    );
    assert!(
        pricing
            .compute_cost(
                Some(InputTokens::try_from(1)?),
                Some(OutputTokens::try_from(0)?),
                None
            )?
            .is_none()
    );
    Ok(())
}
