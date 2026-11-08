//! The payment lifecycle.  `Captured` can only come from a parsed provider reply.

use crate::{
    money::{Cents, PositiveCents},
    order::{Order, OrderError, Placed},
    ports::{ChargeReply, ChargeRequest},
};
use std::fmt;

mod sealed {
    /// Unexported supertrait: no other crate can add a payment state.
    pub trait Sealed {}
}

/// The closed set of payment states.
pub trait PaymentState: sealed::Sealed {}

/// Marker: a charge has been prepared but not confirmed.
#[derive(Debug)]
pub struct Pending;

/// A provider authorization code: non-empty, trimmed, at most 64 bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizationCode(String);

impl AuthorizationCode {
    /// Borrow the code at an output boundary.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Witness: the provider confirmed this exact amount under this code.
#[derive(Debug)]
pub struct Captured {
    authorization: AuthorizationCode,
}

impl sealed::Sealed for Pending {}
impl sealed::Sealed for Captured {}
impl PaymentState for Pending {}
impl PaymentState for Captured {}

/// A payment for one placed order in lifecycle state `S`.
#[derive(Debug)]
pub struct Payment<S: PaymentState> {
    reference: String,
    amount: PositiveCents,
    state: S,
}

/// Why a provider reply does not prove a capture.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureError {
    /// The provider sent no usable authorization code.
    MissingAuthorization,
    /// The provider charged a different amount than requested.
    AmountMismatch,
}

impl fmt::Display for CaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingAuthorization => f.write_str("reply carries no authorization"),
            Self::AmountMismatch => f.write_str("charged amount differs from request"),
        }
    }
}

impl std::error::Error for CaptureError {}

impl Payment<Pending> {
    /// Prepare the payment a placed order requires.
    ///
    /// # Errors
    /// Propagates [`OrderError`] if the amount due is unavailable.
    pub fn for_order(order: &Order<Placed>) -> Result<Self, OrderError> {
        let amount = order.amount_due()?;
        Ok(Self {
            reference: order.id().as_str().to_owned(),
            amount,
            state: Pending,
        })
    }

    /// Describe the effect for the shell; nothing is executed here.
    pub fn charge_request(&self) -> ChargeRequest {
        ChargeRequest::new(self.reference.clone(), self.amount.cents())
    }

    /// Parse the provider reply into a capture, consuming the pending payment.
    ///
    /// # Errors
    /// [`CaptureError::MissingAuthorization`] for an empty or oversized code,
    /// [`CaptureError::AmountMismatch`] if a different amount was charged.
    pub fn capture(self, reply: &ChargeReply) -> Result<Payment<Captured>, CaptureError> {
        let authorization = parse_authorization(reply.authorization())?;
        check_amount(self.amount.cents(), reply.charged())?;
        Ok(Payment {
            reference: self.reference,
            amount: self.amount,
            state: Captured { authorization },
        })
    }
}

impl Payment<Captured> {
    /// The confirmed amount.
    pub fn amount(&self) -> PositiveCents {
        self.amount
    }

    /// The provider's authorization code.
    pub fn authorization(&self) -> &AuthorizationCode {
        &self.state.authorization
    }
}

fn parse_authorization(raw: &str) -> Result<AuthorizationCode, CaptureError> {
    let trimmed = raw.trim();
    let valid = !trimmed.is_empty() && trimmed.len() <= 64;
    valid
        .then(|| AuthorizationCode(trimmed.to_owned()))
        .ok_or(CaptureError::MissingAuthorization)
}

fn check_amount(requested: Cents, charged: Cents) -> Result<(), CaptureError> {
    (requested == charged)
        .then_some(())
        .ok_or(CaptureError::AmountMismatch)
}
