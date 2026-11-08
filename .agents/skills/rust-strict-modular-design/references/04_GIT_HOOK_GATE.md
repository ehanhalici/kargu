# Git Hook Gate: Making the Rules Unskippable on Commit

The compiler proves what types can express; [`hooks/pre-commit`](../hooks/pre-commit)
makes sure every commit is actually checked, and
[`tools/arch-checker`](../tools/arch-checker) adds the rules that are syntactic
but not expressible as types.

## What "guaranteed" means here

| Property | How it is decided | Strength |
|---|---|---|
| Misuse of a typed boundary (private constructor, wrong typestate, forged witness, sealed trait) | `compile_fail,EXXXX` doctests in `cargo test` | **Exact**: the compiler proves it |
| No `unwrap`/`expect`/`panic!`/`todo!`/indexing (library and binary code) | clippy deny list on `--lib --bins` **and** arch-checker | **Exact** for the source as written |
| Tests and benches compile warning-free | `clippy --all-targets -D warnings` | **Exact** |
| No visible struct field; no glob re-export | arch-checker AST rule | **Exact** (decidable syntax) |
| No meaningful primitive in a non-private signature | arch-checker, outside newtype impls and `edge` paths | **Exact** for the configured primitive list |
| Domain modules reach no I/O, clock reads, randomness, printing, `include!`, mutable statics; crate roots not renamed | arch-checker on `domain` paths | **Exact** for the listed paths/macros |
| Domain `pub fn` returns a value (`&mut self` mutators excepted) | arch-checker | **Exact** |
| Known violations never grow and never go stale | `arch-checker.baseline` + ratchet against `HEAD` | **Exact** per rule count |
| "One function, one job" | statements, parameters, nesting limits | **Heuristic**: a proxy, not a proof of intent |
| The commit contains what was checked | the hook exports the *index*, not the working tree | **Exact** |

"Exact" means the rule is a decidable property of the committed source and the
gate rejects every commit that violates it. It does not mean the program is
correct: semantic intent, business rules and runtime behaviour still rely on
types, tests and review.

## Rules (arch-checker)

| Id | Rejects |
|---|---|
| `pub-field` | any non-private struct field (named or tuple) |
| `glob-reexport` | `pub use path::*` |
| `primitive-boundary` | `bool`, `char`, `str`, `String`, integers, floats in a non-private fn signature, also inside `Option`/`Result`/`Vec`/`Box`/maps/refs/tuples; exempt: the newtype's own impl (single-field tuple struct) and `edge` paths |
| `unit-return` | a non-private domain fn returning `()`, except `&mut self` methods (a state transition of the owner) |
| `impure-dependency` | in `domain`: `use`/paths into `std::{fs,net,process,env,io,thread}`, clock reads (`Instant::now`, `SystemTime::now`; holding or comparing a time value is pure), `tokio`, `reqwest`, `hyper`, `ureq`, `rand`, `getrandom`, `chrono::{Utc,Local}`; `println!`-family, `dbg!`, `include!`-family; `use std as x` |
| `global-state` | in `domain`: `static mut`, statics of `Mutex`/`RwLock`/`Cell`/`RefCell`/`Once*`/`Lazy*`/`Atomic*`, `thread_local!` |
| `panic` | `.unwrap()`, `.expect()`, `.unwrap_err()`, `.expect_err()`, `.unwrap_unchecked()`, `panic!`, `todo!`, `unimplemented!`, `unreachable!` |
| `too-many-statements` / `too-many-parameters` / `too-deep` | body, `self`-less parameter count, nested control flow over the configured limits (`else if` chains, match arms and closure bodies count once) |

`#[cfg(test)]` modules (inline or out-of-line `mod tests;` files) and `#[test]`
functions are skipped; only `src/` is scanned.
Each rule is pinned by [`tests/rules.rs`](../tools/arch-checker/tests/rules.rs):
the `violations` fixture must trigger every rule at an exact `file:line:col`,
and the `allowed` fixture and the reference crate must stay clean.

## Opting a crate in

Put `arch-checker.conf` next to the crate's `Cargo.toml`:

```ini
# Pure modules: no I/O, clock, randomness, globals or printing.
domain = src/money.rs src/order.rs src/payment.rs src/invoice.rs
# Edge modules face the outside world and may expose primitives.
edge = src/ports.rs
# Shell modules perform effects; every other rule still applies.
shell = src/shell.rs
max-statements = 15
max-params = 3
max-nesting = 3
```

A path's role is decided by the **longest** matching prefix (`src/a` covers
`src/a.rs` and `src/a/…`), so `domain = src` plus a few `shell`/`edge` entries
makes every new file pure by default. Unlisted paths behave like `shell`.
Unknown keys, a non-positive limit, or no `domain` path are errors (exit 2),
never a silent pass.

### Existing code: the ratchet baseline

A crate that cannot be clean on day one still opts in completely:

```sh
arch-checker --write-baseline arch-checker.baseline .   # once, then commit it
```

The baseline lists each known violation as `rule<TAB>file<TAB>message` with
line numbers and counts removed, so moving code does not churn it. With the
file present the hook runs `arch-checker --baseline arch-checker.baseline
--ratchet <HEAD's baseline>`, which fails when

- a finding is not in the baseline (a **new** violation),
- a baseline entry matches no finding (**stale**: it was fixed, so delete the
  line in the same commit; the file can only tell the truth), or
- any rule has more baseline entries than in `HEAD` (the baseline **grew**;
  counting per rule lets files be renamed without letting violations in).

So the number of violations per rule is monotonically non-increasing, commit
by commit, until the baseline is empty and can be deleted. Run it by hand with
`cargo run --manifest-path tools/arch-checker/Cargo.toml -- path/to/crate`.

## Installing the hook

```sh
.agents/skills/rust-strict-modular-design/hooks/install.sh
```

It writes `.git/hooks/pre-commit`, which calls the versioned script. An
existing, different hook is preserved as `pre-commit.chained` and runs first.

On each commit the hook:

1. exports the staged index into `.git/arch-checker-cache/snapshot`, cleared
   first (unstaged edits cannot hide or fix anything; the fixed path keeps
   cargo's change tracking exact);
2. finds opted-in crates (directories with `Cargo.toml` + `arch-checker.conf`)
   touched by the commit;
3. builds the checker from the snapshot; if the checker itself changed, runs
   its rule fixtures first and re-checks every opted-in crate;
4. per crate runs `cargo fmt --check`, `cargo clippy --all-targets -D warnings`,
   the panic-free deny list on `--lib --bins`, `cargo test` (including
   `compile_fail` proofs) and `arch-checker` (with baseline and ratchet).

Build output is cached in `.git/arch-checker-cache`. Without `cargo` on `PATH`
the hook uses the repository's `shell.nix`.

## Known limits and how to close them

- **`git commit --no-verify` skips local hooks.** Run
  `hooks/pre-commit --all` in CI on every push and protect the branch. In CI
  the ratchet compares with `HEAD` itself; also compare the baseline with the
  merge base (`arch-checker --baseline … --ratchet <merge-base baseline>`).
- **Weakening the checker in the same commit.** The rule fixtures must still
  pass, so a weakened rule must also edit `tests/rules.rs`, which is visible in
  review. Require review for `tools/arch-checker/`.
- **Code produced by macros** (declarative or procedural) is not expanded; the
  checker sees the invocation only. Keep domain modules free of code-generating
  macros, or check the expanded output (`cargo expand`) in CI.
- **Paths not on the lists** (a new I/O crate) are allowed until added to
  `IMPURE`. Pair the checker with a dependency allow-list for domain crates
  (`cargo deny`) when the domain lives in its own crate.
- **Semantic single responsibility** is approximated by size metrics. The
  one-sentence rule and review questions in
  [03](03_MODULE_LAYOUT_AND_ENFORCEMENT.md#6-design-review-questions) remain
  the authority.

## Kargu

`kargu-core` is opted in as a whole ([`kargu-core/arch-checker.conf`](../../../../kargu-core/arch-checker.conf)):
`domain = src`, the JSON-RPC/API wire layer is `edge`, and the actors, workers
and adapters that perform I/O, clock reads or tokio work are listed one by one
as `shell`. Existing violations live in
[`kargu-core/arch-checker.baseline`](../../../../kargu-core/arch-checker.baseline)
and may only shrink. When fixing one, delete its baseline line in the same
commit (or regenerate with `--write-baseline` and check that the diff only
removes lines). Kargu's own gates still apply in addition; follow
[verification-and-testing](../../verification-and-testing/SKILL.md).
