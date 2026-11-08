//! Imperative shell: sequences the pure modules and runs the one effect.
//! It decides nothing itself; it only orders calls and maps errors.

use crate::{
    invoice::{self, Invoice, InvoiceError},
    order::{Draft, Order, OrderError},
    payment::{CaptureError, Payment},
    ports::{GatewayError, PaymentGateway},
};
use std::fmt;

/// Every way a checkout can end without an invoice.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CheckoutError {
    /// The order was not placeable.
    Order(OrderError),
    /// The provider failed or declined.
    Gateway(GatewayError),
    /// The provider reply did not prove a capture.
    Capture(CaptureError),
    /// The captured payment does not settle the order.
    Invoice(InvoiceError),
}

impl fmt::Display for CheckoutError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Order(error) => write!(f, "checkout: {error}"),
            Self::Gateway(error) => write!(f, "checkout: {error}"),
            Self::Capture(error) => write!(f, "checkout: {error}"),
            Self::Invoice(error) => write!(f, "checkout: {error}"),
        }
    }
}

impl std::error::Error for CheckoutError {}

/// Place `draft`, charge it through `gateway` and issue its invoice.
///
/// # Errors
/// The first failing step, wrapped in its [`CheckoutError`] variant.  The
/// provider is never called for an order that cannot be placed.
pub fn checkout<G: PaymentGateway>(
    gateway: &mut G,
    draft: Order<Draft>,
) -> Result<Invoice, CheckoutError> {
    let order = draft.place().map_err(CheckoutError::Order)?;
    let pending = Payment::for_order(&order).map_err(CheckoutError::Order)?;
    let reply = gateway
        .charge(&pending.charge_request())
        .map_err(CheckoutError::Gateway)?;
    let captured = pending.capture(&reply).map_err(CheckoutError::Capture)?;
    invoice::issue(&order, &captured).map_err(CheckoutError::Invoice)
}
