//! The shell runs against an in-memory adapter; the domain needs no mocks.

use order_billing::{
    money::Cents,
    order::{Order, OrderError, OrderId, Quantity},
    ports::{ChargeReply, ChargeRequest, GatewayError, PaymentGateway},
    shell::{CheckoutError, checkout},
};

/// Scripted provider: replies with what each test configures.
struct Scripted {
    reply: Result<(String, Option<Cents>), GatewayError>,
    seen: Vec<ChargeRequest>,
}

impl PaymentGateway for Scripted {
    fn charge(&mut self, request: &ChargeRequest) -> Result<ChargeReply, GatewayError> {
        self.seen.push(request.clone());
        let (code, charged) = self.reply.clone()?;
        Ok(ChargeReply::new(code, charged.unwrap_or(request.amount())))
    }
}

fn gateway(reply: Result<(&str, Option<u64>), GatewayError>) -> Scripted {
    Scripted {
        reply: reply.map(|(code, cents)| (code.to_owned(), cents.map(Cents::new))),
        seen: Vec::new(),
    }
}

fn draft(
    lines: &[(u64, u64)],
) -> Result<Order<order_billing::order::Draft>, Box<dyn std::error::Error>> {
    let mut order = Order::new(OrderId::parse("ORD-42")?);
    for (price, count) in lines {
        let quantity = Quantity::new(*count).ok_or("quantity out of range")?;
        order = order.add_line(Cents::new(*price), quantity)?;
    }
    Ok(order)
}

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn captured_payment_produces_the_invoice() -> TestResult {
    let mut provider = gateway(Ok(("AUTH-1", None)));
    let invoice = checkout(&mut provider, draft(&[(250, 2), (100, 1)])?)?;
    assert_eq!(invoice.amount().cents(), Cents::new(600));
    assert_eq!(invoice.authorization().as_str(), "AUTH-1");
    assert_eq!(invoice.order_id().as_str(), "ORD-42");
    assert_eq!(provider.seen.len(), 1);
    Ok(())
}

#[test]
fn no_invoice_without_a_valid_capture() -> TestResult {
    let cases = [
        (gateway(Err(GatewayError::Declined)), "declined"),
        (gateway(Ok(("   ", None))), "authorization"),
        (gateway(Ok(("AUTH-2", Some(599)))), "differs"),
    ];
    for (mut provider, expected) in cases {
        let error = checkout(&mut provider, draft(&[(600, 1)])?)
            .err()
            .ok_or("invoiced")?;
        assert!(error.to_string().contains(expected), "{error}");
    }
    Ok(())
}

#[test]
fn unplaceable_orders_never_reach_the_provider() -> TestResult {
    let mut provider = gateway(Ok(("AUTH-3", None)));
    let empty = checkout(&mut provider, draft(&[])?);
    assert_eq!(empty, Err(CheckoutError::Order(OrderError::Empty)));
    let free = checkout(&mut provider, draft(&[(0, 3)])?);
    assert_eq!(free, Err(CheckoutError::Order(OrderError::FreeOrder)));
    assert!(provider.seen.is_empty());
    Ok(())
}

#[test]
fn boundary_types_reject_invalid_input_once() -> TestResult {
    assert!(OrderId::parse("ORD-").is_err());
    assert!(OrderId::parse("ord-1").is_err());
    assert!(Quantity::new(0).is_none());
    assert!(Quantity::new(1000).is_none());
    let two = Quantity::new(2).ok_or("quantity out of range")?;
    let overflow = Order::new(OrderId::parse("ORD-1")?).add_line(Cents::new(u64::MAX), two);
    assert!(matches!(overflow, Err(OrderError::Total(_))));
    Ok(())
}
