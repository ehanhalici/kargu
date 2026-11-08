//! Issuing an invoice.  The signature alone forbids invoicing an unpaid order.

use crate::{
    money::PositiveCents,
    order::{Order, OrderError, OrderId, Placed},
    payment::{AuthorizationCode, Captured, Payment},
};
use std::fmt;

/// An issued invoice.  Only `issue` can create one.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Invoice {
    order_id: OrderId,
    amount: PositiveCents,
    authorization: AuthorizationCode,
}

/// Why a captured payment does not settle this order.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InvoiceError {
    /// The order's amount could not be determined.
    Order(OrderError),
    /// The payment covers a different amount than the order.
    AmountMismatch,
}

impl fmt::Display for InvoiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Order(error) => write!(f, "order: {error}"),
            Self::AmountMismatch => f.write_str("payment does not match order amount"),
        }
    }
}

impl std::error::Error for InvoiceError {}

/// Issue the invoice for `order`, settled by the captured `payment`.
///
/// # Errors
/// [`InvoiceError::AmountMismatch`] if the payment does not cover exactly the
/// amount due; [`InvoiceError::Order`] if the order total is unavailable.
pub fn issue(order: &Order<Placed>, payment: &Payment<Captured>) -> Result<Invoice, InvoiceError> {
    let due = order.amount_due().map_err(InvoiceError::Order)?;
    if due != payment.amount() {
        return Err(InvoiceError::AmountMismatch);
    }
    Ok(Invoice {
        order_id: order.id().clone(),
        amount: due,
        authorization: payment.authorization().clone(),
    })
}

impl Invoice {
    /// The settled order's identifier.
    pub fn order_id(&self) -> &OrderId {
        &self.order_id
    }

    /// The invoiced amount.
    pub fn amount(&self) -> PositiveCents {
        self.amount
    }

    /// The payment authorization printed on the invoice.
    pub fn authorization(&self) -> &AuthorizationCode {
        &self.authorization
    }
}
