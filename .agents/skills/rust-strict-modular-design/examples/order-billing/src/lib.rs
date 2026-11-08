//! Order → payment → invoice, built to the rust-strict-modular-design rules.
//!
//! Each module owns exactly one responsibility and talks to the others only
//! through `pub fn` and opaque types.  Invalid states are unrepresentable, so
//! the misuses below are compile errors, not runtime checks.
//!
//! An order id cannot be built without validation (the field is private):
//! ```compile_fail,E0603
//! let _ = order_billing::order::OrderId("x".to_owned());
//! ```
//!
//! A placed order cannot be edited:
//! ```compile_fail,E0599
//! # use order_billing::{money::Cents, order::{Order, OrderId, Quantity}};
//! # fn f(placed: Order<order_billing::order::Placed>) {
//! let _ = placed.add_line(Cents::new(1), Quantity::new(1).unwrap());
//! # }
//! ```
//!
//! An invoice cannot be issued for a payment that was not captured:
//! ```compile_fail,E0308
//! # use order_billing::{invoice, order::{Order, Placed}, payment::{Payment, Pending}};
//! # fn f(order: &Order<Placed>, pending: &Payment<Pending>) {
//! let _ = invoice::issue(order, pending);
//! # }
//! ```
//!
//! The payment lifecycle cannot be extended from outside (sealed trait):
//! ```compile_fail,E0277
//! struct Refunded;
//! impl order_billing::payment::PaymentState for Refunded {}
//! ```
//!
//! A capture witness cannot be forged without parsing a provider reply:
//! ```compile_fail,E0451
//! let _ = order_billing::payment::Captured { authorization: String::new() };
//! ```

pub mod invoice;
pub mod money;
pub mod order;
pub mod payment;
pub mod ports;
pub mod shell;
