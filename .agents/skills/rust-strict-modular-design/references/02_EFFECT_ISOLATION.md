# Effect Isolation: Functional Core, Imperative Shell, Monadic Boundaries

Every interaction with the outside world (network, disk, processes, clock,
randomness, environment, user input, logging that matters) is an *effect*.
Effects are where reality disagrees with your types, so they are confined to
one thin layer and their results re-enter the domain only after parsing.

## 1. The three layers

```
 adapters (impl ports; real I/O)      ← may fail in any way
 ─────────────── ports (traits + request/reply values) ───────────────
 shell (orchestration: sequence calls, map errors, decide nothing)
 ─────────────────────────────────────────────────────────────────────
 core modules (pure, deterministic, typed)
```

- **Core** modules (`order`, `payment`, `invoice`): pure functions over typed
  values. Same input, same output. No I/O, no clock, no randomness, no globals.
- **Ports** (`ports`): traits for each effect plus the value types that cross
  them. Requests are built by the core; replies are *untrusted* data.
- **Shell** (`shell`): one function per use case that wires core calls and
  port calls together and maps errors. It contains no business rule.
- **Adapters**: implement the ports against real systems (or in memory for
  tests). They live outside the core modules, often in another crate.

## 2. Effects as data

The core never performs an effect; it *describes* it. The shell executes it.

```rust
impl Payment<Pending> {
    /// Describe the effect for the shell; nothing is executed here.
    pub fn charge_request(&self) -> ChargeRequest {
        ChargeRequest::new(self.reference.clone(), self.amount.cents())
    }
}
```

`ChargeRequest::new` is `pub(crate)`: adapters can read a request but cannot
invent one, so every charge provably originates from a pending payment.

## 3. Ports

```rust
pub trait PaymentGateway {
    /// # Errors
    /// [`GatewayError::Declined`] for a refusal, [`GatewayError::Unreachable`]
    /// when the outcome is unknown.
    fn charge(&mut self, request: &ChargeRequest) -> Result<ChargeReply, GatewayError>;
}
```

Rules:
- One port per external capability, with the smallest method set the domain
  needs. No "god" client trait.
- Port methods take and return port value types, never domain internals and
  never a dependency's types (`reqwest::Response`, `std::io::Error`).
- Inject ports as generic bounds (`fn checkout<G: PaymentGateway>`) by default;
  use `&mut dyn Port` only where dynamic choice is required.
- Async: the same shape with `async fn` in the trait (or a boxed future);
  cancellation and deadlines belong to the shell/adapter, not the core.

## 4. Replies are parsed into evidence

An adapter reports what it saw (`ChargeReply::new(code, charged)`); the core
decides what it means. Only the core can turn a reply into a witness:

```rust
pub fn capture(self, reply: &ChargeReply) -> Result<Payment<Captured>, CaptureError> {
    let authorization = parse_authorization(reply.authorization())?;
    check_amount(self.amount.cents(), reply.charged())?;
    Ok(Payment { reference: self.reference, amount: self.amount, state: Captured { authorization } })
}
```

Never build a success state directly from an adapter value.

## 5. The shell is a `Result` pipeline

`Result` and `Option` are Rust's monads: `?` is bind, `map`/`and_then`/`map_err`
/`ok_or`/`then_some` are the combinators. The shell reads top to bottom and
short-circuits on the first failure:

```rust
pub fn checkout<G: PaymentGateway>(gateway: &mut G, draft: Order<Draft>) -> Result<Invoice, CheckoutError> {
    let order = draft.place().map_err(CheckoutError::Order)?;
    let pending = Payment::for_order(&order).map_err(CheckoutError::Order)?;
    let reply = gateway.charge(&pending.charge_request()).map_err(CheckoutError::Gateway)?;
    let captured = pending.capture(&reply).map_err(CheckoutError::Capture)?;
    invoice::issue(&order, &captured).map_err(CheckoutError::Invoice)
}
```

Forbidden outside tests: `unwrap`, `expect`, `panic!`, `todo!`,
`unimplemented!`, `unreachable!`, slice indexing, `as` casts, unchecked
arithmetic. Each has a total alternative (`?`, `get`, `try_from`, `checked_*`).

## 6. Error algebra

- **One closed enum per module** (`OrderError`, `CaptureError`, `InvoiceError`),
  each variant a distinct, actionable reason. No `String` errors, no
  `Box<dyn Error>` in signatures.
- **Outer errors wrap inner ones** (`CheckoutError::Gateway(GatewayError)`), so
  the caller can still match the cause while the inner module stays private.
- **Infrastructure vs domain**: "declined" (the provider said no) and
  "unreachable" (we do not know what happened) are different variants. An
  unknown outcome is never reported as failure *or* success, and is never
  retried blindly for side-effecting operations.
- Implement `Display` and `std::error::Error` (or use `thiserror` where the
  project allows dependencies); keep messages free of secrets and payloads.

## 7. Testing

- Core functions: plain unit tests, no mocks needed (they are pure).
- Shell: integration tests with an in-memory adapter that records requests and
  scripts replies (see [tests/checkout.rs](../examples/order-billing/tests/checkout.rs)).
  Assert both the result and that no effect was issued when it must not be
  (`provider.seen.is_empty()`).
- Real adapters: a small contract suite shared by fake and real adapters, run
  against a local fixture, never a live paid service by default.
