# Model metadata: next native boundary

## Status and observed evidence — 2026-10-25

Default HTTP resilience is native at 71dc32d (40); live-model metadata is NOT
yet migrated. This is an evidence/sequence note, not a new implementation or
a declaration that the existing numeric bugs are fixed.

Read-only fresh Emacs reproduction against current source:

```
kargu--read-input-cost on pricing.prompt="invalid9" => 0
kargu--zero-price-p "invalid9" => t
kargu--read-number 1.5 => 2
kargu--read-input-cost on pricing.prompt="0.0000001" => Lisp float
```

The digit-anywhere check followed by string-to-number can turn a malformed
price into a zero/free badge. Fractional token metadata is rounded. These are
legacy behavior findings, not native accounting authority: current native
budget gates observed request/token usage, not exact-price reservation. G08
hard monetary cap is still open; do not claim the UI badge enforces money.

## Owners and consumers to move together

- api/catalog.el holds heterogeneous field/number/price/effort/capability
  extraction, /models body normalization and display formatting. Leave actual
  editor label rendering in Lisp, move semantic normalization to native.
- models/store.el is currently the sole local metadata/override writer. Provider
  identity normalizes, opaque model ID keeps case; unique aliases are local,
  ambiguous aliases refuse. Refresh retains explicit overrides; empty successful
  catalogs prune only that provider. These contracts must survive the cutover.
- api/request.el captures :metadata/:fields/:tools/:tuning in connection settings.
  HTTP request parameters must still use exact provider/model metadata, never a
  fuzzy display alias or data from another provider.
- Existing custom setters and many immediate UI getters are synchronous. Simply
  replacing every getter with RPC or starting a sidecar from a getter violates
  nonblocking UI/ownership. Do not silently change setter completion semantics.
  Resolve staging/committed publication and its compatibility port before the
  consumer cutover; preserve the original API contracts in mapped tests.

## Implementation constraints from 01

1. Native normalization uses bounded raw input and parses semantic private
   newtypes at TryFrom/FromStr/serde boundaries. Reuse api::ModelId where its
   invariants fit, not a second case-folded model identifier. Context capacity,
   output capacity and usage counts are different units, not interchangeable
   u64 or one catch-all TokenCount.
2. Prices never pass through f64, including an intermediate JSON/Lisp number
   that has already rounded the original price. Native remote normalization
   must see exact source lexemes or a proven lossless decimal representation.
   Manual price input must likewise have an explicit lossless contract. Decide
   bounded rational/fixed-point precision and overflow behavior before billing;
   a too-small price must not round into free. MicroUsd is a billed-amount unit,
   not a fractional USD-per-token rate. No dependency/feature change is implied
   by this note; evaluate exact parsing options with tests first.
3. Missing, invalid, zero and positive price are distinct; input/output/cache
   rates are distinct. An input-zero marketing badge is not proof every billed
   component is free. Unknown prices cannot authorize a hard monetary cap.
   Correct the malformed=>zero behavior in the native replacement, not by
   copying the permissive string-to-number algorithm.
4. Preserve absent/false/null capability distinctions, declared effort paths,
   nonempty/empty parameter semantics and exact parameter owner. Unknown field
   normalization must not fabricate capability or token limits.
5. One native owner publishes a revisioned canonical model view; asynchronous
   HTTP workers report observations, not mutate the store. UI holds detached
   projections, never another semantic merge/override/counter engine. Connection
   preparation waits for its captured committed metadata revision, without
   blocking the mailbox or accepting a newer foreign/provider selection.
6. Bounded catalogs/projections must fit paged IPC; keep the 1 MiB frame limit.
   Cancel/close/old-epoch/late refresh must not republish removed or foreign data.
   A malformed catalog must not masquerade as a successful empty catalog.

## Acceptance sequence

- Exact numeric/identity/capability domain fixtures first: invalid9, negative,
  fractional token count, huge exponent/digits, sub-micro prices, exact zero,
  missing prices and checked arithmetic; compile-fail unit/constructor proofs.
- Native canonical extraction and revision/override owner with provider-local
  aliases, empty catalog pruning and typed failures; no UI/network calls in pure
  normalization and no raw credentials in snapshots/logs.
- Owned async publication and preparation barrier; real Emacs -> core -> local
  /models fixtures, manual override completion, frozen connection settings,
  stale/foreign/closed/cancelled owner and out-of-order refresh tests.
- Map test-model-store.el, test-metadata.el, test-dynamic-models.el and request/
  connection tests to actual native contracts before deleting the old semantic
  readers/store writer. Preserve label rendering and synchronous detached reads.
- Locked native/fmt/strict Clippy, touched Werror/checkdoc and full source ERT;
  document intentional strict numeric corrections, then commit the verified
  consumer cutover. No updated baseline may hide missing assertions.

No production metadata change was made by the initial audit above. 01, user
shell.nix and 07 edits remain untouched. No external API/account/application
turn ran.

## Exact numeric foundation

Added private ContextCapacity/OutputCapacity and InputTokenRate/OutputTokenRate
domain types under models/numeric, closed NumericError and constructor/serde
boundaries. Rates use u128 coefficient and bounded decimal scale (0–38), with
128-byte input bound and checked coefficient/exponent arithmetic; unsupported
precision/overflow is an error, never underflow-to-free or saturation. Prices
serialize as exact decimal strings. Capacities require positive integral u64;
1.5 is rejected, exact 1.0/2e3 may parse without rounding. Input/output rates,
context/output capacities and billed MicroUsd cannot be interchanged.

Six native numeric fixture tests and three new compile-fail unit/private-field
proofs passed. Full native gate: **221 tests + 13 compile-fail**, locked build,
fmt and strict all-targets Clippy passed. This foundation alone does NOT switch
the current Elisp metadata readers/store or fix their invalid9/free behavior.

Important integration finding: globally enabling serde_json/arbitrary_precision
passed native fixtures but real GUI/stdio tests exposed an incompatibility with
the custom duplicate-key visitor (a number arrives through serde's private
number-map representation). That experiment was removed, not worked around by
weakening IPC key rejection. Only scoped serde_json/raw_value is enabled;
RawValue keeps metadata number lexemes before exact parsing without changing
ordinary IPC Value deserialization or numeric identity/admission semantics.
Cargo.lock/dependency versions are unchanged. Catalog numeric source text must
cross this scoped boundary before any generic JSON number conversion.
The rebuilt scoped-feature binary passed **1186/1186 full source ERT**,
0 unexpected, **124.97 s**. The failed global-feature experiment is not counted
as a passing gate; existing IPC/admission tests were retained unchanged.
