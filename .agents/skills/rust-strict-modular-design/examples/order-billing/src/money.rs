//! Money arithmetic in integer cents.  Overflow is a value, never a panic.

use std::fmt;

/// A non-negative amount in cents.  Floats are never used for money.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd)]
pub struct Cents(u64);

/// Why a money operation produced no value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MoneyError {
    /// The result would not fit in the representation.
    Overflow,
}

impl fmt::Display for MoneyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("money arithmetic overflow")
    }
}

impl std::error::Error for MoneyError {}

impl Cents {
    /// Wrap an amount; every `u64` is a valid non-negative amount.
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// Borrow the raw amount at an output boundary (rendering, wire).
    pub const fn get(self) -> u64 {
        self.0
    }

    /// Add two amounts, refusing overflow.
    ///
    /// # Errors
    /// [`MoneyError::Overflow`] if the sum does not fit.
    pub fn checked_add(self, other: Self) -> Result<Self, MoneyError> {
        self.0
            .checked_add(other.0)
            .map(Self)
            .ok_or(MoneyError::Overflow)
    }

    /// Multiply by a count, refusing overflow.
    ///
    /// # Errors
    /// [`MoneyError::Overflow`] if the product does not fit.
    pub fn checked_times(self, count: u64) -> Result<Self, MoneyError> {
        self.0
            .checked_mul(count)
            .map(Self)
            .ok_or(MoneyError::Overflow)
    }
}

/// A strictly positive amount: a charge of zero is unrepresentable.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PositiveCents(std::num::NonZeroU64);

impl PositiveCents {
    /// Accept only a non-zero amount.
    pub fn new(amount: Cents) -> Option<Self> {
        std::num::NonZeroU64::new(amount.get()).map(Self)
    }

    /// The amount as plain cents.
    pub const fn cents(self) -> Cents {
        Cents(self.0.get())
    }
}
