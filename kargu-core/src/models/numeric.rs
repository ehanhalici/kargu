//! Exact bounded decimals and non-interchangeable catalog units.
//!
//! A per-token rate is not a billed amount or the other token direction:
//! ```compile_fail
//! use kargu_core::models::{InputTokenRate, OutputTokenRate};
//! fn output(_: OutputTokenRate) {}
//! fn wrong(input: InputTokenRate) { output(input); }
//! ```
//! Cache write pricing cannot substitute for cache read pricing:
//! ```compile_fail
//! use kargu_core::models::{CacheReadTokenRate, CacheWriteTokenRate};
//! fn read(_: CacheReadTokenRate) {}
//! fn wrong(write: CacheWriteTokenRate) { read(write); }
//! ```
//! Context and output capacities are not interchangeable:
//! ```compile_fail
//! use kargu_core::models::{ContextCapacity, OutputCapacity};
//! fn output(_: OutputCapacity) {}
//! fn wrong(context: ContextCapacity) { output(context); }
//! ```
//! Validated values cannot be directly manufactured:
//! ```compile_fail
//! use kargu_core::models::ContextCapacity;
//! let invalid = ContextCapacity(0);
//! ```

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::{fmt, num::NonZeroU64, str::FromStr};

const MAX_LITERAL_BYTES: usize = 128;
const MAX_SCALE: i16 = 38;

/// Closed numeric boundary failures; never carry untrusted literal text.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum NumericError {
    /// Not a complete nonnegative decimal literal.
    #[error("Invalid model numeric literal")]
    Syntax,
    /// Unsupported decimal scale; no rounding into zero is permitted.
    #[error("Model decimal precision exceeds supported bounds")]
    Precision,
    /// The exact value does not fit the target unit.
    #[error("Model numeric value exceeds supported range")]
    Range,
    /// Capacities must be positive, integral token quantities.
    #[error("Model capacity must be a positive integer")]
    Capacity,
}

/// Exact coefficient / 10^scale; canonical zero always has scale zero.
#[derive(Clone, Debug, Eq, PartialEq)]
struct Decimal {
    coefficient: u128,
    scale: u8,
}
impl FromStr for Decimal {
    type Err = NumericError;
    fn from_str(source: &str) -> Result<Self, Self::Err> {
        if source.len() > MAX_LITERAL_BYTES {
            return Err(NumericError::Range);
        }
        let source = source.trim();
        let (mantissa, exponent) = match source.split_once(['e', 'E']) {
            Some((mantissa, exponent)) => {
                let exponent = exponent.parse::<i16>().map_err(|_| NumericError::Syntax)?;
                if !(-MAX_SCALE..=MAX_SCALE).contains(&exponent) {
                    return Err(NumericError::Precision);
                }
                (mantissa, exponent)
            }
            None => (source, 0),
        };
        let (integer, fraction) = mantissa.split_once('.').map_or((mantissa, ""), |pair| pair);
        if integer.is_empty()
            || !integer.bytes().all(|byte| byte.is_ascii_digit())
            || (mantissa.contains('.') && fraction.is_empty())
            || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        {
            return Err(NumericError::Syntax);
        }
        let mut coefficient = 0_u128;
        for byte in integer.bytes().chain(fraction.bytes()) {
            coefficient = coefficient
                .checked_mul(10)
                .and_then(|value| value.checked_add(u128::from(byte.saturating_sub(b'0'))))
                .ok_or(NumericError::Range)?;
        }
        let scale = i16::try_from(fraction.len())
            .map_err(|_| NumericError::Precision)?
            .checked_sub(exponent)
            .ok_or(NumericError::Precision)?;
        if scale > MAX_SCALE {
            return Err(NumericError::Precision);
        }
        let scale = if scale < 0 {
            let power = u32::from(scale.unsigned_abs());
            coefficient = coefficient
                .checked_mul(10_u128.checked_pow(power).ok_or(NumericError::Range)?)
                .ok_or(NumericError::Range)?;
            0
        } else {
            u8::try_from(scale).map_err(|_| NumericError::Precision)?
        };
        Ok(Self::canonical(coefficient, scale))
    }
}
impl Decimal {
    fn canonical(mut coefficient: u128, mut scale: u8) -> Self {
        if coefficient == 0 {
            scale = 0;
        }
        while scale > 0 && coefficient.is_multiple_of(10) {
            coefficient /= 10;
            scale = scale.saturating_sub(1);
        }
        Self { coefficient, scale }
    }
}
impl fmt::Display for Decimal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.scale == 0 {
            return write!(formatter, "{}", self.coefficient);
        }
        let width = usize::from(self.scale);
        let denominator = 10_u128
            .checked_pow(u32::from(self.scale))
            .ok_or(fmt::Error)?;
        write!(
            formatter,
            "{}.{:0width$}",
            self.coefficient / denominator,
            self.coefficient % denominator
        )
    }
}

macro_rules! rate {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, Eq, PartialEq)]
        pub struct $name(Decimal);
        impl FromStr for $name {
            type Err = NumericError;
            fn from_str(source: &str) -> Result<Self, NumericError> {
                source.parse().map(Self)
            }
        }
        impl $name {
            /// Exact zero, never inferred from malformed or rounded text.
            pub fn is_zero(&self) -> bool {
                self.0.coefficient == 0
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.collect_str(self)
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let source = String::deserialize(deserializer)?;
                source.parse().map_err(serde::de::Error::custom)
            }
        }
    };
}
rate!(
    InputTokenRate,
    "Exact USD per input token, not a billed micro-USD amount."
);
rate!(
    OutputTokenRate,
    "Exact USD per output token, distinct from input pricing."
);
rate!(
    CacheReadTokenRate,
    "Exact USD per cached input token read, not an ordinary input rate."
);
rate!(
    CacheWriteTokenRate,
    "Exact USD per cache-write token, not a cache-read rate."
);
impl InputTokenRate {
    /// Exact UI USD/one-million-input-tokens label, never a billed amount.
    /// Decimal shifting uses text, so even u128::MAX cannot overflow on * 1M.
    pub fn per_million_label(&self) -> String {
        if self.is_zero() {
            return "$0.00/1M".to_owned();
        }
        let coefficient = self.0.coefficient.to_string();
        let scale = usize::from(self.0.scale);
        let (integer, fraction) = if scale <= 6 {
            (
                format!("{coefficient}{}", "0".repeat(6_usize.saturating_sub(scale))),
                String::new(),
            )
        } else {
            let scale = scale.saturating_sub(6);
            let digits = format!(
                "{}{}",
                "0".repeat(scale.saturating_add(1).saturating_sub(coefficient.len())),
                coefficient
            );
            let position = digits.len().saturating_sub(scale);
            (
                digits.chars().take(position).collect(),
                digits.chars().skip(position).collect(),
            )
        };
        let padding = "0".repeat(2_usize.saturating_sub(fraction.len()));
        format!("${integer}.{fraction}{padding}/1M")
    }
}

macro_rules! capacity {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
        #[serde(try_from = "u64")]
        pub struct $name(NonZeroU64);
        impl TryFrom<u64> for $name {
            type Error = NumericError;
            fn try_from(value: u64) -> Result<Self, NumericError> {
                NonZeroU64::new(value)
                    .map(Self)
                    .ok_or(NumericError::Capacity)
            }
        }
        impl FromStr for $name {
            type Err = NumericError;
            fn from_str(source: &str) -> Result<Self, NumericError> {
                let value: Decimal = source.parse()?;
                if value.scale != 0 {
                    return Err(NumericError::Capacity);
                }
                Self::try_from(u64::try_from(value.coefficient).map_err(|_| NumericError::Range)?)
            }
        }
        impl $name {
            /// Borrow the validated count only at a DTO/formatting boundary.
            pub fn get(self) -> u64 {
                self.0.get()
            }
        }
    };
}
capacity!(
    ContextCapacity,
    "Positive model context capacity, not output capacity or usage."
);
capacity!(
    OutputCapacity,
    "Positive model output capacity, not context capacity or usage."
);
