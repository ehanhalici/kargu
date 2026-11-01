//! Exact pricing over canonical input totals, with cache subsets charged once.

use crate::{
    domain::{CacheWriteTokens, CachedTokens, InputTokens, MicroUsd, OutputTokens},
    error::CoreError,
    models::{CacheReadTokenRate, CacheWriteTokenRate, InputTokenRate, OutputTokenRate},
};

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
