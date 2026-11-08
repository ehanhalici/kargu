//! Building an order and placing it.  Placing is a one-way typestate change.

use crate::money::{Cents, MoneyError, PositiveCents};
use std::{fmt, marker::PhantomData};

/// An integer known at compile time to lie in `MIN..=MAX`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Bounded<const MIN: u64, const MAX: u64>(u64);

impl<const MIN: u64, const MAX: u64> Bounded<MIN, MAX> {
    /// Accept `value` only inside the compile-time range.
    pub const fn new(value: u64) -> Option<Self> {
        if value >= MIN && value <= MAX {
            Some(Self(value))
        } else {
            None
        }
    }

    /// The validated value.
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// How many units one line orders: never zero, never absurd.
pub type Quantity = Bounded<1, 999>;

/// A validated order identifier: `ORD-` followed by 1–12 ASCII digits.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OrderId(String);

/// Why an order could not be built or placed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrderError {
    /// The identifier does not have the required shape.
    InvalidId,
    /// An order must contain at least one line before it is placed.
    Empty,
    /// The order total does not fit in the money representation.
    Total(MoneyError),
    /// Placing a free order would make payment meaningless.
    FreeOrder,
}

impl fmt::Display for OrderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidId => f.write_str("invalid order id"),
            Self::Empty => f.write_str("order has no lines"),
            Self::Total(error) => write!(f, "order total: {error}"),
            Self::FreeOrder => f.write_str("order total is zero"),
        }
    }
}

impl std::error::Error for OrderError {}

impl OrderId {
    /// Parse an identifier once at the boundary.
    ///
    /// # Errors
    /// [`OrderError::InvalidId`] unless `raw` is `ORD-` and 1–12 ASCII digits.
    pub fn parse(raw: &str) -> Result<Self, OrderError> {
        let digits = raw.strip_prefix("ORD-").ok_or(OrderError::InvalidId)?;
        let valid = (1..=12).contains(&digits.len()) && digits.bytes().all(|b| b.is_ascii_digit());
        valid
            .then(|| Self(raw.to_owned()))
            .ok_or(OrderError::InvalidId)
    }

    /// Borrow the identifier at an output boundary.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Marker: lines may still be added.
#[derive(Debug)]
pub struct Draft;
/// Marker: the order is frozen and has a positive total.
#[derive(Debug)]
pub struct Placed;

/// One priced line of an order.
#[derive(Clone, Copy, Debug)]
struct Line {
    unit_price: Cents,
    quantity: Quantity,
}

/// An order whose capabilities depend on its lifecycle `State`.
#[derive(Debug)]
pub struct Order<State> {
    id: OrderId,
    lines: Vec<Line>,
    total: Cents,
    _state: PhantomData<State>,
}

impl Order<Draft> {
    /// Start an empty draft order.
    pub fn new(id: OrderId) -> Self {
        Self {
            id,
            lines: Vec::new(),
            total: Cents::default(),
            _state: PhantomData,
        }
    }

    /// Add one line, keeping the running total exact.
    ///
    /// # Errors
    /// [`OrderError::Total`] if the line or running total overflows.
    pub fn add_line(mut self, unit_price: Cents, quantity: Quantity) -> Result<Self, OrderError> {
        let line_total = unit_price
            .checked_times(quantity.get())
            .map_err(OrderError::Total)?;
        self.total = self
            .total
            .checked_add(line_total)
            .map_err(OrderError::Total)?;
        self.lines.push(Line {
            unit_price,
            quantity,
        });
        Ok(self)
    }

    /// Freeze the order.  Consumes the draft, so it can never be edited again.
    ///
    /// # Errors
    /// [`OrderError::Empty`] without lines, [`OrderError::FreeOrder`] if the
    /// total is zero.
    pub fn place(self) -> Result<Order<Placed>, OrderError> {
        if self.lines.is_empty() {
            return Err(OrderError::Empty);
        }
        PositiveCents::new(self.total).ok_or(OrderError::FreeOrder)?;
        Ok(Order {
            id: self.id,
            lines: self.lines,
            total: self.total,
            _state: PhantomData,
        })
    }
}

impl Order<Placed> {
    /// The positive amount the customer must pay.
    ///
    /// # Errors
    /// [`OrderError::FreeOrder`] if the total is zero (unreachable for a
    /// placed order, but proved by the type, not assumed).
    pub fn amount_due(&self) -> Result<PositiveCents, OrderError> {
        PositiveCents::new(self.total).ok_or(OrderError::FreeOrder)
    }

    /// The order identifier.
    pub fn id(&self) -> &OrderId {
        &self.id
    }

    /// The line with the highest unit price, for presentation.
    pub fn largest_line(&self) -> Option<(Cents, Quantity)> {
        self.lines
            .iter()
            .max_by_key(|line| line.unit_price)
            .map(|line| (line.unit_price, line.quantity))
    }
}
