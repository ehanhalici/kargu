---
name: rust-strict-modular-design
description: Design and implement Rust code as strictly single-responsibility modules and functions that talk only through public functions, with domain invariants, module boundaries and lifecycle rules encoded in types so the compiler rejects misuse, and with every external effect isolated behind Result-returning ports. Use when architecting, writing, refactoring or reviewing Rust modules, crates or bounded contexts, or when a rule should be enforced at compile time instead of checked at runtime.
---

# Rust Strict Modular Design

Turn every rule you would otherwise check at runtime into something the compiler
checks. A module does one thing, a function does one thing, modules meet only at
`pub fn` boundaries, and the outside world is reached only through ports that
return `Result`.

This skill is generic. In Kargu it complements, and never overrides, the
project rules in [coding-standards](../coding-standards/SKILL.md) and
[01_RUST_CORE_PATTERNS.md](../coding-standards/references/01_RUST_CORE_PATTERNS.md).

## Does Rust have dependent types?

No. Rust cannot make a type depend on an arbitrary runtime value as Idris, Agda,
Lean or F* can. It can, however, get the same practical guarantee for most
domain rules by **proving the rule once at the boundary and carrying the proof
as a type**:

| Need | Rust tool | Example in [examples/order-billing](examples/order-billing) |
|---|---|---|
| "this value satisfies P" | private-field newtype + fallible constructor | `OrderId::parse`, `PositiveCents::new` |
| "this integer is in `MIN..=MAX`" | const generics | `Bounded<1, 999>` = `Quantity` |
| "never zero" | `NonZero*` | `PositiveCents(NonZeroU64)` |
| "only after step X" | typestate (`PhantomData` markers, `self`-consuming transitions) | `Order<Draft>` → `Order<Placed>` |
| "only if X really happened" | witness / proof type constructible only by the module that verified X | `Payment<Captured>` from a parsed `ChargeReply` |
| "no one else may extend this set" | sealed trait | `PaymentState` |
| "these two numbers are different units" | distinct newtypes / phantom unit parameter | `Cents` vs `Quantity` |

What stays a runtime check: relations between two runtime values (an order total
equals a captured amount). Do those checks exactly once, inside the module that
owns the rule, and return a typed error. See
[01_TYPE_LEVEL_TOOLKIT.md](references/01_TYPE_LEVEL_TOOLKIT.md).

## Non-negotiable rules

### 1. Decomposition
1. **One module, one responsibility.** Name it after what it does (`order`,
   `payment`, `invoice`), never `utils`, `common`, `helpers` or `misc`.
2. **One function, one job.** A function either *decides* (pure, small) or
   *orchestrates* (only sequences calls and maps errors). It never does both.
3. **Small by construction.** Bodies ≤ 40 lines, at most 3 parameters (more ⇒ a
   parameter type), cognitive complexity ≤ 10, nesting ≤ 3. Enforced by
   `clippy.toml` (see [03](references/03_MODULE_LAYOUT_AND_ENFORCEMENT.md)).

### 2. Boundaries are code, not convention
4. **Modules communicate only through `pub fn` and opaque types.** No `pub`
   fields, ever. Accessors return borrowed views or `Copy` values.
5. **Expose the minimum.** Default to private; widen to `pub(super)`,
   `pub(crate)`, then `pub`, one step at a time and only for a named caller.
   Constructors that only another domain module should call are `pub(crate)`
   (`ChargeRequest::new`).
6. **No primitive crosses a module boundary carrying meaning.** IDs, amounts,
   counts, limits, paths and states are newtypes. Primitives appear only at the
   very edge (parsing input, rendering output) via `parse`/`get`/`as_str`.
7. **Prove boundaries with `compile_fail` doctests** that name the expected
   error code (`compile_fail,E0603`). Each forbidden use gets one.

### 3. Types carry the invariants
8. **Parse, don't validate.** Validate once in a fallible constructor returning
   `Result<Self, ModuleError>` or `Option<Self>`; downstream code never re-checks.
9. **Lifecycles are typestates.** No `is_paid: bool`; transitions consume `self`
   and return the next state type. Methods exist only on the states that allow them.
10. **Evidence is a type.** If B may only happen after A succeeded, B takes A's
    witness type as a parameter, and only A's module can construct it.
11. **Closed sets are sealed.** State and capability traits get an unexported
    supertrait so no other module or crate can add members.

### 4. Effects are isolated ("monadic" boundaries)
12. **Functional core, imperative shell.** Domain modules are deterministic: no
    I/O, clock, randomness, environment, global state or logging side effects.
13. **Effects are described as data, executed by the shell.** The core returns a
    request value (`ChargeRequest`); a port trait performs it; the reply comes
    back as an *untrusted* value that the core parses into evidence.
14. **Every fallible step returns `Result`/`Option`.** Compose with `?`,
    `map`, `and_then`, `map_err`, `ok_or`, `then`. `unwrap`, `expect`,
    `panic!`, `todo!`, `unimplemented!`, `unreachable!`, indexing `[i]`, `as`
    casts and unchecked arithmetic are forbidden outside tests.
15. **Each module owns a closed error enum.** Errors never leak a dependency's
    type across a boundary; the outer layer wraps inner errors (`CheckoutError::Gateway`).
    Infrastructure failure ("unreachable") stays distinct from a domain refusal.

Details and patterns: [02_EFFECT_ISOLATION.md](references/02_EFFECT_ISOLATION.md).

## Workflow

1. **Split the problem.** Write one sentence per responsibility; each sentence is
   one module. If a sentence needs "and", split it.
2. **Draw the boundary.** For each module list its `pub fn`s and opaque types
   *before* writing bodies. Everything else is private.
3. **Name the invariants.** For each input, write the rule it must satisfy and
   give it a newtype with a fallible constructor.
4. **Encode the lifecycle.** Write the state diagram; each state is a marker
   type, each arrow a `self`-consuming method. Add witness types for
   "only after" rules and seal the state trait.
5. **Find the effects.** Each effect becomes a port trait in a `ports` module,
   with request/reply value types; the core builds requests and parses replies.
6. **Write the shell last.** One orchestrator per use case: sequence calls,
   `map_err` into the use-case error, decide nothing.
7. **Prove it.** Add a `compile_fail,EXXXX` doctest per forbidden use, unit
   tests for each decision function, and integration tests that drive the shell
   with an in-memory adapter.
8. **Gate it.** Apply the lint table and `clippy.toml` from
   [03](references/03_MODULE_LAYOUT_AND_ENFORCEMENT.md), add an
   `arch-checker.conf` naming the pure `domain` and `edge` paths, and install the
   pre-commit gate ([04](references/04_GIT_HOOK_GATE.md)). Run the verification
   commands until all are clean.

## Enforcement on every commit

[`hooks/pre-commit`](hooks/pre-commit) checks the *staged* snapshot of every
opted-in crate with fmt, strict clippy, `cargo test` (the `compile_fail`
proofs) and [`tools/arch-checker`](tools/arch-checker), a `syn` AST gate for
the syntactic rules types cannot express: no visible fields, no glob
re-exports, no primitives across boundaries, pure domain modules, no panics,
and size limits. Existing code opts in with a ratchet baseline that
may only shrink. Install with `hooks/install.sh`; run `hooks/pre-commit --all`
in CI. What is proven exactly and what is only a heuristic is listed in
[04_GIT_HOOK_GATE.md](references/04_GIT_HOOK_GATE.md).

## Review checklist

- [ ] Every module's responsibility fits one sentence without "and".
- [ ] No `pub` field; no `pub use *`; every `pub` item has a named caller.
- [ ] No meaningful primitive in a `pub fn` signature between modules.
- [ ] Each lifecycle is a typestate; no runtime state flags.
- [ ] Each "only after X" rule takes a witness only X's module can build.
- [ ] Each state/capability trait is sealed.
- [ ] Domain modules contain no I/O, clock, randomness or globals.
- [ ] Each effect goes through a port; replies are parsed, not trusted.
- [ ] Each module has its own closed error enum; no foreign error leaks.
- [ ] Each forbidden use has a `compile_fail,EXXXX` doctest that fails for that reason.
- [ ] fmt, strict clippy, tests, doctests and `cargo doc -D warnings` are clean.
- [ ] `arch-checker` is clean and the pre-commit gate is installed (CI runs `--all`).

## Anti-patterns

- **Primitive obsession**: `fn charge(order_id: String, cents: i64)`.
- **Validation sprinkled downstream**: `if qty == 0 { return Err(..) }` in three places.
- **Boolean lifecycle**: `struct Payment { captured: bool }`.
- **Trusting the outside**: building a "captured" state directly from an adapter's reply.
- **God shell**: an orchestrator that computes totals, formats text and retries.
- **Leaky errors**: `Box<dyn Error>` or a dependency's error type in a `pub fn` signature.
- **Visibility by habit**: `pub` everywhere "for testing"; test through the public API instead.
- **Macro magic over types**: a procedural macro where a newtype and a trait would do.

## References

- [01_TYPE_LEVEL_TOOLKIT.md](references/01_TYPE_LEVEL_TOOLKIT.md): newtypes, bounded integers, typestate, witnesses, sealed traits, units, and the limits of each.
- [02_EFFECT_ISOLATION.md](references/02_EFFECT_ISOLATION.md): functional core, ports, effects as data, error algebra, unknown outcomes.
- [03_MODULE_LAYOUT_AND_ENFORCEMENT.md](references/03_MODULE_LAYOUT_AND_ENFORCEMENT.md): file layout, visibility ladder, lint and clippy configuration, compile-fail proofs, verification commands.
- [04_GIT_HOOK_GATE.md](references/04_GIT_HOOK_GATE.md): the pre-commit gate and AST checker, what each rule proves, installation and known limits.
- [examples/order-billing](examples/order-billing): a complete, verified crate applying every rule (order → payment → invoice).
- [tools/arch-checker](tools/arch-checker) and [hooks/](hooks): the enforcement tooling.
