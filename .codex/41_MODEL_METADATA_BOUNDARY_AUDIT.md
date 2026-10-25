# Model metadata: next native boundary

## Approved publication contract — 2026-10-25

The user approved asynchronous setters and synchronous last-committed UI reads
("tamam devam et, uygundur"). Submission is not publication: setters must
return owned asynchronous work, and failure must preserve the last committed
projection. Connection preparation must await its captured metadata intent.
Getters must not start the core, block on RPC, or merge speculative overrides.
The earlier pending-decision notes below are historical, not a current blocker.
Implementation proceeds in independently verified native/domain and consumer
cutover slices; legacy readers are removed only after their consumers move.

Native field foundation now lives in models/metadata (raw/effort/text modules).
Missing/Invalid/Known distinguishes malformed rates from exact zero. Context,
output and cache rates have separate units. Exact RawValue fixtures include
9007199254740992.5 (invalid capacity, never rounded), 1e-38, invalid9 and duplicate
declared reasoning keys. Only declared effort paths are followed, with bounded
names/path lengths/list sizes and explicit disable precedence. Raw inspector
pricing retains exact strings, not floating-point prices. Seven fixtures and
two new compile-fail proofs passed: **238 native + 15 compile-fail**, fmt and
strict all-targets Clippy. No editor consumer changed in this foundation slice;
the existing full ERT result above is not a fresh run for these new modules.

The native store foundation now has consuming PreparedUpdate -> commit, a private
MetadataRevision and an unforgeable original-store UUID binding in addition to
base-revision comparison. A candidate cannot publish into a sibling store even
when both revisions match. Refresh pruning/overrides/unique aliases/refusals/
opaque identity and exact original-number fixtures pass; full gate is **245
native + 16 compile-fail**, fmt/strict Clippy. Store snapshots are detached
projections, not staging, and raw provider/id cannot rewrite canonical ownership.
This is not yet the actor/RPC/editor cutover; retaining the legacy consumer until
that boundary is verified is intentional.

Additional parser finding: serde internally-tagged enum deserialization buffers
through Content and cannot retain Box<RawValue> source spans. Update commands
therefore first decode a closed operation tag, then its direct deny_unknown_fields
DTO from the original source. Do not replace this with Value/from_value or an
internally-tagged raw DTO that loses exact source support. Numeric and store
fixtures exercise the actual source path; no global serde feature is enabled.

## Native actor/RPC publication foundation

The application actor now owns ModelService/ModelStore. model_metadata exposes
models/begin, append, commit, abort, snapshot and read under the existing exact
application/session ReadScope. One bounded upload per application has a random
typed identity, captured provider/specs/base revision, exact typed byte offset
and absolute 60-second validity. Expiry is reaped on the next call; no hidden
timer or external await blocks the actor. Session/app close discards staging.
Completed RPC calls are not pending executions: cancelling a client publication
must explicitly abort its captured upload ID; a late begin response must be
cleaned up rather than acquiring another owner or reconnecting silently.

Input remains <=8 MiB, <=16 KiB UTF-8 append, <=20,000 records; the canonical
projection is <=16 MiB and is serialized once per preparation. Pages honor the
negotiated frame, including the 1 KiB minimum, with worst-case JSON escape room
and UTF-8 boundaries. A read requires the exact committed revision, so a newer
commit fails an old paged download instead of producing a mixed snapshot.
Malformed/aborted/expired uploads never publish. A failed/unknown commit ACK must
not authorize an old UI cache for connection preparation; reconciliation belongs
to the upcoming owned async editor port, not a synchronous getter RPC.

Six actual stdio fixtures cover staging/ping/commit/replay, sibling application
and sibling session denial, invalid offsets/abort/invalid command atomicity,
large escaped Unicode paging and old-revision rejection, the minimum negotiated
frame, and session/application-close followed by actual shutdown/exit/reap.
Two deterministic native tests cover absolute expiry and the 8 MiB upload bound.
An additional store fixture verifies refusal observations cannot erase captured
effort paths; clearing refusals retains the legacy all-provider scope.

The editor is NOT cut over by advertising this capability. The original HTTP
catalog record sources retained by ModelCatalog::into_records are exact only
inside the native domain. The existing into_snapshot/default discovery path
still needs its numeric-capacity source-preservation consumer cutover: do not
re-upload a fraction already decoded through generic Value/Lisp floats and
claim it is exact. UI setters must reject manual floating-point prices in favor
of exact decimal text/integer input. Map existing synchronous tests to real owned
async completion, keep synchronous getters as detached reads, await the captured
submission (not a newer unrelated queue tail), and freeze that ticket's exact
projection in connection settings before deleting legacy readers/writers.

Final native actor/RPC gate: **254 native + 16 compile-fail**, fmt, locked build
and strict all-targets Clippy passed. The rebuilt normal-feature binary passed
**1191/1191 full source ERT**, 0 unexpected, **125.91 s**, at 17:17:56
Europe/Istanbul. Production Lisp was not changed or bytecompiled by these
native foundations, and no elc files were generated. No abstract TLC result is
presented as a proof of this concrete metadata revision/publication refinement.

## Canonical UI projection, before the public producer cutover

model_metadata_projection additionally advertises native display/default/alias
permission DTOs. Unknown fields remain unknown and missing/invalid prices never
produce a zero/free label. USD per million input-token display uses exact decimal
text shifting, not f64 or overflowing rate * 1M arithmetic, including 1e-38 and
u128::MAX fixtures. Native aliases carry their own request-identity refusal
permission; request parameters still require an exact model record. The initial
and committed snapshots both include native unknown-model defaults. Gate:
**256 native + 16 compile-fail**, fmt, locked build and strict all-targets Clippy.
This DTO foundation is not yet the default Lisp setter/catalog/UI cutover.

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

## Native discovery envelope consumer cutover

Default /models now captures the GET-only model_catalog response profile. The
api_model_catalog capability is required before application startup or request
delivery. Ordinary raw GET/POST keeps its prior contract; a missing capability
does not cause a raw fallback after network side effects. A generative POST
cannot select the discovery profile. Unexpected SSE/sniffed non-JSON never
publishes a discovery event.

models/catalog parses bounded raw JSON once at the heterogeneous boundary and
returns only {models: [...]} with canonical typed ModelId identity. data/models/
items/bare-array and string ID records converge here; Google models/ prefix is
removed, opaque case/namespaces and input order survive. Duplicate envelope,
record and pricing-object keys fail, rather than last-key-wins admission.
Repeated model IDs retain existing ordered-record/last metadata behavior; this
slice does not add another alias/override store. Other opaque nested objects
are not advertised as a universal duplicate-key rejection boundary.

Malformed/missing/null lists and provider errors are NOT successful emptiness;
only an explicit empty array clears the corresponding owned cache. Unknown/
invalid record identity fails the whole response before publication, not a
silent filtered-empty success. Limits are 8 MiB raw discovery / 20,000 records,
in addition to captured HTTP raw limits and the existing paged body/1 MiB frame
gate. Known pricing object/direct input/output-cost numeric lexemes become
lossless strings before generic JSON decoding. No f64 money calculation is
introduced. This preserves source precision for the subsequent rate parser;
it does not yet fix legacy field-reader invalid9/free classification.

Deleted kargu--extract-models-from-json and kargu--catalog-response. The editor
now decodes the single canonical vector, checks its projection shape and keeps
the existing captured provider/generation/application callback. It does not
recognize provider envelopes or echo raw error bodies. Existing mock callback
fixtures now supply canonical DTOs; original raw envelope assertions moved to
native pure/socket tests and real public GUI -> core -> loopback cases. No old
assertions, module baseline or cache/pruning/freshness requirements were dropped.

Six native catalog fixtures + three HTTP profile tests cover envelopes,
identity, duplicate keys, malformed/null/error, exact price lexemes, hard bounds,
GET-only/SSE refusal. Five new real editor tests cover public provider discovery,
unchanged cache on errors versus explicit empty prune, bare-ID refresh clearing
old capabilities, >1 MiB paging/exact price strings, and missing capability
before owner/GET startup. **230 native + 13 compile-fail**, fmt/strict Clippy
passed; **90/90 focused ERT** passed. Touched two production Elisp files passed
Werror compilation; their two generated elc artifacts were removed before the
full source rerun. Checkdoc is clean apart from environment OpenPGP autoload.
Final source rerun passed **1191/1191 full ERT**, 0 unexpected, **126.19 s**
at 12:23:42 Europe/Istanbul. One legacy application-owner callback fixture
also needed the canonical envelope; its actual owner assertions were retained.

Still open: full typed field/capability/rate normalization, native revisioned
store/overrides and preparation barrier. The existing synchronous custom setter
contract is unchanged in this slice. The user was asked whether an explicit
async completion plus last-committed UI snapshot contract is acceptable for that
next cutover; no silent setter semantic change has been implemented.

## Executable feature-interaction regression gate

Added a native protocol test through the actual duplicate-key decoder, not
serde_json::from_value alone. It proves ordinary temperature numbers remain
numbers and deserialize into the bounded request-tuning type, u64 quantities
retain their integer kind, a literal private-number-key object remains an
object, and nested duplicate keys still fail. This covers the interaction
missed by the original pure HTTP/domain fixtures.

Negative control: explicitly enabling serde_json/arbitrary_precision makes
this exact new test fail (expected exit 101 at the number-kind assertion).
The production manifest remains scoped raw_value only; no decoder exception
or third-party private-key handling was introduced to force a green result.
Default locked gates are rerun afterward and the normal binary is rebuilt.
This is a test-only guard, not another production migration or a new feature.
Default final gate passed **231 native + 13 compile-fail**, fmt/strict Clippy
and locked build. With the restored normal binary **12/12 real default chat/
catalog ERT** passed. Production sources are unchanged since 8331fd5; the full
1191/1191 source ERT above remains its gate, not a newly claimed full rerun for
this test-only addition. The optional negative-control feature is not present
in the shipped manifest or the final binary. No generated elc files remain.
