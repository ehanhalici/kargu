# Type-Level Toolkit: Getting Dependent-Type Guarantees in Rust

Rust has no first-class dependent types: a type cannot mention an arbitrary
runtime value (`Vec<T, n>` where `n` is read from a file). What it does have is
enough to make most domain rules unrepresentable when broken:

> **Prove once at the boundary, then carry the proof as a type.**

Every tool below follows the same shape: a *private* representation, one
*fallible* way in, and no way to build the value without passing the check.
All code is taken from, or verified alongside, [examples/order-billing](../examples/order-billing).

## 1. Refinement newtypes (parse, don't validate)

The field is private, so the only way to obtain the type is the constructor.

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OrderId(String);

impl OrderId {
    pub fn parse(raw: &str) -> Result<Self, OrderError> {
        let digits = raw.strip_prefix("ORD-").ok_or(OrderError::InvalidId)?;
        let valid = (1..=12).contains(&digits.len()) && digits.bytes().all(|b| b.is_ascii_digit());
        valid.then(|| Self(raw.to_owned())).ok_or(OrderError::InvalidId)
    }
    pub fn as_str(&self) -> &str { &self.0 }
}
```

Rules:
- Construct with `parse`/`new`/`TryFrom`; return `Result` (needs a reason) or
  `Option` (absence is the only failure).
- No `Default`, `From<String>` or public tuple field that bypasses the check.
- With serde, use `#[serde(try_from = "String")]` so deserialization runs the
  same constructor; never derive `Deserialize` on the raw field.
- Expose the inside only at output edges (`as_str`, `get`), never `&mut`.

## 2. Bounded integers with const generics

The bounds are part of the type, so `Quantity` and `Percent` cannot be mixed
and every `Quantity` is known to be in range.

```rust
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Bounded<const MIN: u64, const MAX: u64>(u64);

impl<const MIN: u64, const MAX: u64> Bounded<MIN, MAX> {
    pub const fn new(value: u64) -> Option<Self> {
        if value >= MIN && value <= MAX { Some(Self(value)) } else { None }
    }
    pub const fn get(self) -> u64 { self.0 }
}

pub type Quantity = Bounded<1, 999>;
```

`const fn` lets literal values be checked at compile time:
`const ONE: Quantity = match Quantity::new(1) { Some(q) => q, None => panic!() };`
(the `panic!` runs in const evaluation, so an out-of-range literal is the
*compile* error `E0080`, not a runtime one; keep such constants in one module
and `#[allow(clippy::panic)]` locally).

## 3. Non-zero and other standard refinements

Prefer the standard zero-cost types: `NonZeroU64`, `NonZeroUsize`, `NonNull`.
They also give niche optimisation (`Option<NonZeroU64>` is 8 bytes).

```rust
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PositiveCents(std::num::NonZeroU64);

impl PositiveCents {
    pub fn new(amount: Cents) -> Option<Self> {
        std::num::NonZeroU64::new(amount.get()).map(Self)
    }
}
```

## 4. Typestate: lifecycles the compiler enforces

States are zero-sized marker types; transitions consume `self`; methods exist
only where they are legal. A placed order has no `add_line`, so calling it is
`E0599`.

```rust
pub struct Draft;
pub struct Placed;

pub struct Order<State> {
    id: OrderId,
    lines: Vec<Line>,
    total: Cents,
    _state: std::marker::PhantomData<State>,
}

impl Order<Draft> {
    pub fn add_line(mut self, price: Cents, qty: Quantity) -> Result<Self, OrderError> { /* … */ }
    pub fn place(self) -> Result<Order<Placed>, OrderError> { /* checks, then */ }
}
impl Order<Placed> {
    pub fn amount_due(&self) -> Result<PositiveCents, OrderError> { /* … */ }
}
```

Rules:
- Never a `bool`/`enum` flag plus runtime `if` for a lifecycle a caller could
  get wrong. Use an `enum` only when the state is genuinely chosen at runtime
  and every arm is handled.
- Transitions that can fail return `Result<NextState, Error>` and give the old
  value back inside the error only if the caller must retry with it.
- Keep the marker set closed with a sealed trait (§6) when it is generic.

## 5. Witness (evidence) types: "only if X really happened"

Typestate says *which step you are in*; a witness says *what was proven*. The
witness carries data only the proving module can produce, and its fields are
private, so forging it is `E0451`.

```rust
pub struct Captured { authorization: String }   // field private to `payment`

impl Payment<Pending> {
    pub fn capture(self, reply: &ChargeReply) -> Result<Payment<Captured>, CaptureError> {
        let authorization = parse_authorization(reply.authorization())?;
        check_amount(self.amount.cents(), reply.charged())?;
        Ok(Payment { reference: self.reference, amount: self.amount, state: Captured { authorization } })
    }
}

// In another module: the signature alone forbids invoicing an unpaid order.
pub fn issue(order: &Order<Placed>, payment: &Payment<Captured>) -> Result<Invoice, InvoiceError> { /* … */ }
```

Capability tokens are the same idea for permissions: a function that needs
approval takes `&Approved<Action>`, and only the approval module can mint one.

```rust
pub struct Approved<A> { action: A }          // no public constructor

pub fn approve<A>(action: A, decision: Decision) -> Option<Approved<A>> {
    matches!(decision, Decision::Yes).then_some(Approved { action })
}
pub fn execute(approved: Approved<DeleteFile>) -> Result<(), IoError> { /* … */ }
```

## 6. Sealed traits: closed sets nobody else can extend

```rust
mod sealed { pub trait Sealed {} }

pub trait PaymentState: sealed::Sealed {}
impl sealed::Sealed for Pending {}
impl sealed::Sealed for Captured {}
impl PaymentState for Pending {}
impl PaymentState for Captured {}
```

Outside the module, `impl PaymentState for Refunded {}` fails with `E0277`.
Seal every trait whose implementor set is part of your invariants (states,
capabilities, units). Do not seal port traits: adapters must implement them.

## 7. Units and dimensions

Different meanings get different types even when the representation is equal.
For many units, a phantom unit parameter avoids one newtype per unit:

```rust
pub struct Bytes;
pub struct Tokens;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Amount<U> { value: u64, _unit: std::marker::PhantomData<U> }

impl<U> Amount<U> {
    pub const fn new(value: u64) -> Self { Self { value, _unit: std::marker::PhantomData } }
    pub fn checked_add(self, other: Self) -> Option<Self> {
        self.value.checked_add(other.value).map(Self::new)
    }
}
// `Amount<Bytes>::checked_add(Amount<Tokens>)` is E0308.
```

## 8. What the type system cannot prove (and what to do instead)

| Rule | Why types can't hold it | Do this |
|---|---|---|
| "captured amount equals order total" | relation between two runtime values | check once in the owning module, return a typed error (`InvoiceError::AmountMismatch`) |
| "this file still exists" | the world changes after the check | re-check at the effect, return `Result`, never cache truth |
| "this list is sorted" | mutation could break it | wrap in a newtype with no `&mut` access and sorted-only constructors |
| "n items, n from input" | no value-dependent lengths | `Vec` inside a newtype that validates the length; const generics only for compile-time sizes |

If a rule can only be checked at runtime, it is still checked *once*, in *one*
module, and its success is recorded in a type.

## 9. Proving the boundary

Each forbidden use is a `compile_fail` doctest with its expected error code, so
a refactor that accidentally opens the boundary breaks the build:

```rust
//! ```compile_fail,E0599
//! # fn f(placed: order_billing::order::Order<order_billing::order::Placed>) {
//! let _ = placed.add_line(/* … */);
//! # }
//! ```
```

Verify that each block fails *for that reason* (rustdoc checks error codes only
on nightly): see the probe procedure in
[03_MODULE_LAYOUT_AND_ENFORCEMENT.md](03_MODULE_LAYOUT_AND_ENFORCEMENT.md#proving-compile_fail-blocks).
