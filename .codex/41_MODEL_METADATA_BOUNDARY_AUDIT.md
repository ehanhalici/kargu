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

No production metadata change was made by this audit. 01, user shell.nix and
07 edits remain untouched. No external API/account/application turn ran.
