# Module Layout, Visibility and Enforcement

Rules that live only in a document drift. This file turns the skill into
compiler, linter and test failures.

## 1. Layout

One file (or folder) per responsibility. The crate root only declares modules.

```
src/
  lib.rs        // module declarations + crate-level compile_fail proofs
  money.rs      // integer money arithmetic
  order.rs      // building and placing an order (typestate)
  payment.rs    // payment lifecycle (sealed states, capture witness)
  invoice.rs    // issuing an invoice from evidence
  ports.rs      // effect traits + request/reply values
  shell.rs      // use-case orchestration only
tests/
  checkout.rs   // shell driven by an in-memory adapter
```

A folder module (`order/mod.rs` + children) is right when one responsibility
needs private helpers; `mod.rs` then declares children as private (`mod line;`)
and re-exports only the public surface by name (`pub use line::Line;`), never
with `*`.

## 2. The visibility ladder

| Level | Use for |
|---|---|
| private (default) | everything until a caller needs it |
| `pub(super)` | a parent module's orchestration of its own children |
| `pub(crate)` | constructors other domain modules may call but adapters must not (`ChargeRequest::new`) |
| `pub` | the module's contract: its `pub fn`s, opaque types, error enum, port traits |

- Struct fields are never `pub`. A struct is either opaque (fields private,
  accessors) or a sealed marker.
- `unreachable_pub` (denied below) flags `pub` items that are not actually
  reachable from the crate root, which keeps "pub by habit" out.
- Tests use the public API. Do not widen visibility for tests; if a rule is
  hard to test through the API, the module is doing too much.

## 3. Lints: make the rules errors

Put this in the crate's `Cargo.toml` (as in the example crate):

```toml
[lints.rust]
unsafe_code = "forbid"
missing_docs = "deny"
unreachable_pub = "deny"

[lints.clippy]
unwrap_used = "deny"
expect_used = "deny"
panic = "deny"
indexing_slicing = "deny"
arithmetic_side_effects = "deny"
as_conversions = "deny"
todo = "deny"
unimplemented = "deny"
unreachable = "deny"
excessive_nesting = "deny"
shadow_unrelated = "deny"
missing_errors_doc = "deny"
dbg_macro = "deny"
print_stdout = "deny"
too_many_lines = "deny"
cognitive_complexity = "deny"
```

And `clippy.toml` for the single-responsibility size limits:

```toml
too-many-lines-threshold = 40
cognitive-complexity-threshold = 10
too-many-arguments-threshold = 3
excessive-nesting-threshold = 3
```

Exceptions are local, justified and rare: `#[allow(clippy::panic)]` on a
const-evaluated constructor (see 01 §2), or `#[expect(...)]` with a comment
naming the reason. Never relax a lint crate-wide to make code compile.

In an existing project (Kargu), match the project's own lint table and add
these only where the project standard allows; the project rules win.

## 4. Proving `compile_fail` blocks

Each forbidden use gets a doctest in the crate root (or the owning module):

```rust
//! ```compile_fail,E0451
//! let _ = order_billing::payment::Captured { authorization: String::new() };
//! ```
```

Stable rustdoc only checks that the block *fails*, not *why*. A typo also
fails, which would make the proof worthless. Verify the reason once per block
and after each refactor that touches it:

1. Create a scratch binary crate depending on the library by path.
2. Paste the block body into `main.rs` (inside a function if it is a statement).
3. `cargo build` and confirm the reported error code equals the annotated one
   and the message names the intended boundary (private field, missing method,
   unsatisfied sealed bound, mismatched state type).

The example crate's five blocks were verified this way:
`E0603` (private constructor), `E0599` (no `add_line` on `Placed`), `E0308`
(`Pending` where `Captured` is required), `E0277` (sealed trait), `E0451`
(private witness field).

## 5. Verification commands

Run from the crate directory; all must be clean before a change is done:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test                      # unit, integration and compile_fail doctests
RUSTDOCFLAGS="-D warnings" cargo doc --no-deps
cargo run --manifest-path <skill>/tools/arch-checker/Cargo.toml -- .   # AST gate
```

The pre-commit gate runs these on every commit; see
[04_GIT_HOOK_GATE.md](04_GIT_HOOK_GATE.md).

In Kargu, run these inside the Nix shell (`nix-shell --run '…'`) and follow
[verification-and-testing](../../verification-and-testing/SKILL.md) for the
project's own gates.

## 6. Design review questions

Ask these of every new or changed module before writing its bodies:

1. What is the one sentence this module is responsible for?
2. Which `pub fn`s and types form its contract, and who calls each?
3. Which inputs carry rules, and which newtype proves each rule?
4. Which steps must happen in order, and which typestate encodes the order?
5. Which actions require prior evidence, and which witness type carries it?
6. Which effects does it need, and which port describes each?
7. Which errors can it return, and does each variant tell the caller what to do?
8. Which misuses should not compile, and is there a verified `compile_fail` block for each?
