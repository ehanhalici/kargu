//! Parse-once limits and provider observations. No estimated text/token conversion.

use crate::{
    constants::limits,
    domain::{CacheWriteTokens, CachedTokens, InputTokens, MicroUsd, OutputTokens, TokenCount},
    error::CoreError,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Maximum charged attempts, with a hard bound on retained accounting tickets.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct RequestLimit(u64);
impl TryFrom<u64> for RequestLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if !(1..=limits::API_BUDGET_ATTEMPTS).contains(&value) {
            return Err(CoreError::InvalidValue {
                field: "RequestLimit",
            });
        }
        Ok(Self(value))
    }
}
impl Default for RequestLimit {
    fn default() -> Self {
        Self(30)
    }
}
impl RequestLimit {
    pub(super) fn count(self) -> u64 {
        self.0
    }
}

/// Maximum logical compactions; a transport retry is not another compaction.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct CompactionLimit(u64);
impl TryFrom<u64> for CompactionLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value > limits::API_BUDGET_COMPACTIONS {
            return Err(CoreError::InvalidValue {
                field: "CompactionLimit",
            });
        }
        Ok(Self(value))
    }
}
impl CompactionLimit {
    pub(super) fn count(self) -> u64 {
        self.0
    }
    fn one() -> Self {
        Self(1)
    }
}

/// Positive observed-token ceiling; not a hard reservation or monetary bound.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct TokenLimit(TokenCount);
impl TryFrom<u64> for TokenLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 {
            return Err(CoreError::InvalidValue {
                field: "TokenLimit",
            });
        }
        Ok(Self(TokenCount::try_from(value)?))
    }
}
impl TokenLimit {
    pub(super) fn count(self) -> TokenCount {
        self.0
    }
}

/// Observed-spend ceiling in integer micro-dollars; admission reserves no future cost.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(try_from = "u64")]
pub struct MonetaryLimit(MicroUsd);
impl TryFrom<u64> for MonetaryLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 {
            return Err(CoreError::InvalidValue {
                field: "MonetaryLimit",
            });
        }
        Ok(Self(MicroUsd::try_from(value)?))
    }
}
impl MonetaryLimit {
    /// Exact micro-dollar amount.
    pub fn amount(self) -> MicroUsd {
        self.0
    }
}

/// Immutable run intent; omitted token cap means unknown usage remains observable.
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetLimits {
    #[serde(default)]
    requests: RequestLimit,
    #[serde(default = "CompactionLimit::one")]
    compactions: CompactionLimit,
    #[serde(default)]
    tokens: Option<TokenLimit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    monetary: Option<MonetaryLimit>,
}
impl Default for BudgetLimits {
    fn default() -> Self {
        Self {
            requests: RequestLimit::default(),
            compactions: CompactionLimit::one(),
            tokens: None,
            monetary: None,
        }
    }
}
impl BudgetLimits {
    /// Capture already parsed quantities once.
    pub fn new(
        requests: RequestLimit,
        compactions: CompactionLimit,
        tokens: Option<TokenLimit>,
    ) -> Self {
        Self {
            requests,
            compactions,
            tokens,
            monetary: None,
        }
    }
    /// Attach an optional observed monetary ceiling.
    pub fn with_monetary(mut self, monetary: Option<MonetaryLimit>) -> Self {
        self.monetary = monetary;
        self
    }
    pub(super) fn requests(self) -> RequestLimit {
        self.requests
    }
    pub(super) fn compactions(self) -> CompactionLimit {
        self.compactions
    }
    pub(super) fn tokens(self) -> Option<TokenLimit> {
        self.tokens
    }
    pub(super) fn monetary(self) -> Option<MonetaryLimit> {
        self.monetary
    }
}

/// Why one physical attempt was admitted to the common gate.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DebitKind {
    /// Initial conversation request.
    NormalRequest,
    /// Another physical transport attempt, including retrying a compaction.
    RetryAttempt,
    /// First attempt of a logical compaction turn.
    CompactionTurn,
    /// Agent diagnostic repair request.
    HealingTurn,
    /// Further model output after a bounded continuation decision.
    Continuation,
}

/// Only actual provider input/output counters. Cache/reasoning are subsets here.
#[derive(Clone, Copy, Debug, Default)]
pub struct ObservedUsage {
    input: Option<InputTokens>,
    output: Option<OutputTokens>,
}
impl ObservedUsage {
    /// Capture exact measured counters; absence is not a zero measurement.
    pub fn new(input: Option<InputTokens>, output: Option<OutputTokens>) -> Self {
        Self { input, output }
    }
    pub(super) fn total(self) -> Result<TokenCount, CoreError> {
        TokenCount::try_from(self.input.map_or(0, InputTokens::as_u64))?.checked_add(
            TokenCount::try_from(self.output.map_or(0, OutputTokens::as_u64))?,
        )
    }
    pub(super) fn unknown(self) -> bool {
        self.input.is_none() || self.output.is_none()
    }
}
impl TryFrom<&Value> for ObservedUsage {
    type Error = CoreError;
    fn try_from(response: &Value) -> Result<Self, CoreError> {
        fn count(usage: Option<&Value>, field: &'static str) -> Result<Option<u64>, CoreError> {
            match usage.and_then(|usage| usage.get(field)) {
                None | Some(Value::Null) => Ok(None),
                Some(value) => value.as_u64().map(Some).ok_or(CoreError::InvalidValue {
                    field: "ObservedUsage",
                }),
            }
        }
        let usage = response.get("usage");
        if usage.is_some_and(|value| !value.is_null() && !value.is_object()) {
            return Err(CoreError::InvalidValue {
                field: "ObservedUsage",
            });
        }
        Ok(Self {
            input: count(usage, "prompt_tokens")?
                .map(InputTokens::try_from)
                .transpose()?,
            output: count(usage, "completion_tokens")?
                .map(OutputTokens::try_from)
                .transpose()?,
        })
    }
}

/// Conservative upper bounds for an admission reservation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttemptBounds {
    input: InputTokens,
    output: OutputTokens,
    cache_write: Option<CacheWriteTokens>,
    cache_read: Option<CachedTokens>,
}

impl AttemptBounds {
    /// Construct bounds with prompt input and completion output limits.
    pub fn new(input: InputTokens, output: OutputTokens) -> Self {
        Self {
            input,
            output,
            cache_write: None,
            cache_read: None,
        }
    }

    /// Attach an optional cache-creation upper bound.
    pub fn with_cache_write(mut self, cache_write: CacheWriteTokens) -> Result<Self, CoreError> {
        if cache_write.as_u64() > self.input.as_u64() {
            return Err(CoreError::InvalidValue {
                field: "AttemptBounds",
            });
        }
        self.cache_write = Some(cache_write);
        Ok(self)
    }

    /// Prompt input tokens upper bound.
    pub fn input(&self) -> InputTokens {
        self.input
    }

    /// Completion output tokens upper bound.
    pub fn output(&self) -> OutputTokens {
        self.output
    }

    /// Cache write tokens upper bound.
    pub fn cache_write(&self) -> Option<CacheWriteTokens> {
        self.cache_write
    }

    /// Cache read tokens upper bound.
    pub fn cache_read(&self) -> Option<CachedTokens> {
        self.cache_read
    }
}
