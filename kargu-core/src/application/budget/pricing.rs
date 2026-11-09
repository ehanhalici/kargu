//! Exact pricing over canonical input totals, with cache subsets charged once.

use crate::{
    application::budget::{AttemptBounds, ObservedUsage, Refusal},
    domain::{CacheWriteTokens, CachedTokens, InputTokens, MicroUsd, OutputTokens},
    error::CoreError,
    models::{CacheReadTokenRate, CacheWriteTokenRate, InputTokenRate, OutputTokenRate},
};
use serde_json::Value;

/// Complete observed billing counters. Missing cache data cannot become zero.
/// Canonical input includes both cache subsets, after provider normalization.
/// Cache creation and cache reads cannot substitute for one another:
/// ```compile_fail
/// use kargu_core::{application::budget::PricingUsage,
///     domain::{InputTokens, OutputTokens, CachedTokens, CacheWriteTokens}};
/// fn swapped(input: InputTokens, output: OutputTokens, read: CachedTokens,
///            write: CacheWriteTokens) {
///     PricingUsage::new(input, output, write, read);
/// }
/// ```
pub struct PricingUsage {
    uncached: InputTokens,
    output: OutputTokens,
    cache_read: CachedTokens,
    cache_write: CacheWriteTokens,
}
impl PricingUsage {
    /// Parse disjoint cache subsets against the inclusive canonical input total.
    /// Construct only when every billing counter is actually known.
    pub fn new(
        total_input: InputTokens,
        output: OutputTokens,
        cache_read: CachedTokens,
        cache_write: CacheWriteTokens,
    ) -> Result<Self, CoreError> {
        let uncached = total_input
            .as_u64()
            .checked_sub(cache_read.as_u64())
            .and_then(|remaining| remaining.checked_sub(cache_write.as_u64()))
            .ok_or(CoreError::InvalidValue {
                field: "PricingUsage",
            })?;
        Ok(Self {
            uncached: InputTokens::try_from(uncached)?,
            output,
            cache_read,
            cache_write,
        })
    }
    /// Total inclusive input tokens before cache subtraction.
    pub fn total_input(&self) -> Result<InputTokens, CoreError> {
        let total = self
            .uncached
            .as_u64()
            .checked_add(self.cache_read.as_u64())
            .and_then(|t| t.checked_add(self.cache_write.as_u64()))
            .ok_or(CoreError::ArithmeticOverflow)?;
        InputTokens::try_from(total)
    }
    /// Output completion tokens.
    pub fn output(&self) -> OutputTokens {
        self.output
    }
    /// Cache read tokens subset.
    pub fn cache_read(&self) -> CachedTokens {
        self.cache_read
    }
    /// Cache write tokens subset.
    pub fn cache_write(&self) -> CacheWriteTokens {
        self.cache_write
    }
    /// Uncached input tokens.
    pub fn uncached(&self) -> InputTokens {
        self.uncached
    }
    /// Convert to observed usage with canonical total input.
    pub fn observed_usage(&self) -> Result<ObservedUsage, CoreError> {
        Ok(ObservedUsage::new(
            Some(self.total_input()?),
            Some(self.output),
        ))
    }
}

fn parse_counter(val: Option<&Value>) -> Result<Option<u64>, CoreError> {
    match val {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v.as_u64().map(Some).ok_or(CoreError::InvalidValue {
            field: "PricingUsage",
        }),
    }
}

impl TryFrom<&Value> for PricingUsage {
    type Error = CoreError;
    fn try_from(response: &Value) -> Result<Self, CoreError> {
        let usage = match response.get("usage") {
            Some(Value::Object(_)) => response.get("usage"),
            _ if response.is_object() && response.get("prompt_tokens").is_some() => Some(response),
            _ => None,
        }
        .ok_or(CoreError::InvalidValue {
            field: "PricingUsage",
        })?;
        let prompt_raw =
            parse_counter(usage.get("prompt_tokens"))?.ok_or(CoreError::InvalidValue {
                field: "PricingUsage",
            })?;
        let completion_raw =
            parse_counter(usage.get("completion_tokens"))?.ok_or(CoreError::InvalidValue {
                field: "PricingUsage",
            })?;
        let details = usage.get("prompt_tokens_details");
        let cached_raw = parse_counter(details.and_then(|d| d.get("cached_tokens")))?.unwrap_or(0);
        let write_raw =
            parse_counter(details.and_then(|d| d.get("cache_write_tokens")))?.unwrap_or(0);
        let input = InputTokens::try_from(prompt_raw)?;
        let output = OutputTokens::try_from(completion_raw)?;
        let read = CachedTokens::try_from(cached_raw)?;
        let write = CacheWriteTokens::try_from(write_raw)?;
        Self::new(input, output, read, write)
    }
}

/// Captured exact per-category rates; absence is distinct from a free category.
#[derive(Clone, Debug, Default)]
pub struct PricingRates {
    input: Option<InputTokenRate>,
    output: Option<OutputTokenRate>,
    cache_read: Option<CacheReadTokenRate>,
    cache_write: Option<CacheWriteTokenRate>,
}
impl PricingRates {
    /// Capture rates without substituting normal input pricing for cache pricing.
    pub fn new(
        input: Option<InputTokenRate>,
        output: Option<OutputTokenRate>,
        cache_read: Option<CacheReadTokenRate>,
        cache_write: Option<CacheWriteTokenRate>,
    ) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
        }
    }
    /// Price complete observed usage without rounding or counting cache twice.
    /// Incomplete usage, a required missing rate or fractional final micro-USD
    /// remains unknown. This calculation does not reserve future expenditure.
    pub fn compute_cost(
        &self,
        usage: Option<&PricingUsage>,
    ) -> Result<Option<MicroUsd>, CoreError> {
        let Some(usage) = usage else {
            return Ok(None);
        };
        let mut cost = ExactCost::default();
        macro_rules! charge {
            ($rate:expr, $tokens:expr) => {
                if $tokens > 0 {
                    let Some(rate) = $rate.as_ref() else {
                        return Ok(None);
                    };
                    cost.add(rate.charge_tokens($tokens)?)?;
                }
            };
        }
        charge!(self.input, usage.uncached.as_u64());
        charge!(self.output, usage.output.as_u64());
        charge!(self.cache_read, usage.cache_read.as_u64());
        charge!(self.cache_write, usage.cache_write.as_u64());
        Ok((cost.remainder == 0).then_some(cost.whole))
    }
    /// Price the worst-case reservation for bounded attempt counters.
    ///
    /// Rounds up fractional micro-USD so no spend right is invented.
    /// If output is unbounded, returns `Refusal::UnboundedOutput`.
    /// If required rates are missing, returns `Refusal::UnknownPricing`.
    pub fn compute_reservation(&self, bounds: &AttemptBounds) -> Result<MicroUsd, Refusal> {
        if bounds.output().as_u64() == 0 {
            return Err(Refusal::UnboundedOutput);
        }
        let mut cost = ExactCost::default();
        self.charge_output(&mut cost, bounds.output())?;
        self.charge_input_and_cache(&mut cost, bounds)?;
        Self::finalize_reservation(cost)
    }
    fn charge_output(&self, cost: &mut ExactCost, output: OutputTokens) -> Result<(), Refusal> {
        let rate = self.output.as_ref().ok_or(Refusal::UnknownPricing)?;
        let charge = rate
            .charge_tokens(output.as_u64())
            .map_err(|_| Refusal::Accounting)?;
        cost.add(charge).map_err(|_| Refusal::Accounting)
    }
    fn charge_input_and_cache(
        &self,
        cost: &mut ExactCost,
        bounds: &AttemptBounds,
    ) -> Result<(), Refusal> {
        let write_tokens = bounds.cache_write().map_or(0, |w| w.as_u64());
        let uncached = bounds
            .input()
            .as_u64()
            .checked_sub(write_tokens)
            .ok_or(Refusal::Accounting)?;
        if write_tokens > 0 {
            let rate = self.cache_write.as_ref().ok_or(Refusal::UnknownPricing)?;
            let charge = rate
                .charge_tokens(write_tokens)
                .map_err(|_| Refusal::Accounting)?;
            cost.add(charge).map_err(|_| Refusal::Accounting)?;
        }
        if uncached > 0 {
            let rate = self.input.as_ref().ok_or(Refusal::UnknownPricing)?;
            let charge = rate
                .charge_tokens(uncached)
                .map_err(|_| Refusal::Accounting)?;
            cost.add(charge).map_err(|_| Refusal::Accounting)?;
        }
        Ok(())
    }
    fn finalize_reservation(cost: ExactCost) -> Result<MicroUsd, Refusal> {
        if cost.remainder > 0 {
            cost.whole
                .checked_add(MicroUsd::ONE)
                .map_err(|_| Refusal::Accounting)
        } else {
            Ok(cost.whole)
        }
    }
}

/// A local exact micro-dollar sum; decimal-rate denominators are powers of ten.
struct ExactCost {
    whole: MicroUsd,
    remainder: u128,
    denominator: u128,
}
impl Default for ExactCost {
    fn default() -> Self {
        Self {
            whole: MicroUsd::ZERO,
            remainder: 0,
            denominator: 1,
        }
    }
}
impl ExactCost {
    fn add(
        &mut self,
        (whole, remainder, denominator): (MicroUsd, u128, u128),
    ) -> Result<(), CoreError> {
        let common = self.denominator.max(denominator);
        let previous = self
            .remainder
            .checked_mul(common / self.denominator)
            .ok_or(CoreError::ArithmeticOverflow)?;
        let incoming = remainder
            .checked_mul(common / denominator)
            .ok_or(CoreError::ArithmeticOverflow)?;
        // Reduce before summing: two fractions can carry without overflowing
        // even when their common decimal denominator is near u128::MAX.
        let distance = common
            .checked_sub(incoming)
            .ok_or(CoreError::ArithmeticOverflow)?;
        let (remainder, carry) = if previous >= distance {
            (previous.checked_sub(distance), 1)
        } else {
            (previous.checked_add(incoming), 0)
        };
        let whole = self
            .whole
            .checked_add(whole)?
            .checked_add(MicroUsd::try_from(carry)?)?;
        self.remainder = remainder.ok_or(CoreError::ArithmeticOverflow)?;
        self.denominator = common;
        self.whole = whole;
        Ok(())
    }
}
