//! The only doors to the outside world.  Adapters implement these traits;
//! the domain never touches a network, clock or disk directly.

use crate::money::Cents;
use std::fmt;

/// What the shell asks a payment provider to do.  Built only by `payment`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeRequest {
    reference: String,
    amount: Cents,
}

impl ChargeRequest {
    /// Describe a charge; called by the payment module, never by adapters.
    pub(crate) fn new(reference: String, amount: Cents) -> Self {
        Self { reference, amount }
    }

    /// Idempotency reference the provider must echo.
    pub fn reference(&self) -> &str {
        &self.reference
    }

    /// Amount to charge.
    pub fn amount(&self) -> Cents {
        self.amount
    }
}

/// An untrusted provider answer.  It proves nothing until `payment` parses it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeReply {
    authorization: String,
    charged: Cents,
}

impl ChargeReply {
    /// Record what an adapter observed, without judging it.
    pub fn new(authorization: String, charged: Cents) -> Self {
        Self {
            authorization,
            charged,
        }
    }

    /// Raw authorization code reported by the provider.
    pub fn authorization(&self) -> &str {
        &self.authorization
    }

    /// Amount the provider reports as charged.
    pub fn charged(&self) -> Cents {
        self.charged
    }
}

/// Infrastructure failure, kept separate from domain errors.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GatewayError {
    /// The provider refused the charge.
    Declined,
    /// The provider could not be reached; the effect is unknown.
    Unreachable,
}

impl fmt::Display for GatewayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Declined => f.write_str("charge declined"),
            Self::Unreachable => f.write_str("payment provider unreachable"),
        }
    }
}

impl std::error::Error for GatewayError {}

/// Port: perform one charge.  The only effectful operation in this crate.
pub trait PaymentGateway {
    /// Execute `request` against the real provider.
    ///
    /// # Errors
    /// [`GatewayError::Declined`] for a refusal, [`GatewayError::Unreachable`]
    /// when the outcome is unknown.
    fn charge(&mut self, request: &ChargeRequest) -> Result<ChargeReply, GatewayError>;
}
