# 01 strict audit — implementation evidence

## 2026-10-25 — API body-page unit

Finding: the IPC admission, retry intent, worker and body publisher passed a raw
`usize` page capacity. The publisher revalidated zero/progress on every call.
This violated 01's unit separation and parse-once contracts, despite Clippy
passing. `ApiPageBytes` now has a private field and is constructed once with
`TryFrom<ByteLimit>` before resource admission. It reserves JSON/envelope space,
caps each page at 32 KiB, and guarantees at least four bytes (one UTF-8 scalar).
The publisher no longer revalidates these established invariants.

Evidence: exact frame/page boundary and multibyte minimum-page lossless body
tests, plus a wrong-unit compile-fail example. Full locked native suite:
**208 tests + 6 compile-fail**, fmt and strict Clippy pass. Last full source ERT
is the independently verified **1185/1185** from the immediately preceding GUI
slice; no editor behavior/source changed here.

## 2026-10-25 — Resource-owning retry typestate

Replaced the independent stage/charge/retry Options and optional-result tuple.
The DTO converts once through `TryFrom<Request>` into Single or Retry intent;
Retry necessarily contains a budget reference and a generative HTTP request.
No later missing-budget/retry Option revalidation reconstructs that contract.

`api/resilience/exchange.rs` encodes consuming phases: Attempt<Ticket> -> Retired
-> Backoff -> ObserverReady -> (explicit headless ReplayReady OR
Observing<Correlation> -> Observed -> accepted ReplayReady) -> Attempt<Ticket>.
Tokens express sequencing, NOT budget/owner/ACK authority; those checks still
belong to the mailbox. Backoff carries no usage ticket, observation owns the
exact reverse identity, and a new attempt requires a fresh physical charge.

`ipc/api/flight.rs` stores heterogeneous live phases in an exhaustive enum.
Runtime matching remains at the worker-observation boundary, where mismatched
completion types really are an internal protocol fault; no temporary missing
stage or retry-without-charge state is representable in the registry.
Normal transitions consume the previous phase. EOF first revokes reverse calls,
joins all workers, collects exact returned usage once, then retires retained
logical circuit grants; no early slot release or actor-side IO wait was added.

Evidence: three compile-fail contracts (backoff cannot admit, an active attempt
cannot observe, one replay token cannot be reused), a positive full phase-chain
test, and the existing real stdio/HTTP admission, wait/observer close, EOF,
deadline, budget, no-visible-replay and sole-probe regressions. Full native:
**209 tests + 9 compile-fail** passed. Final typed-error mapping change also
passed all 15 live retry/circuit tests and strict Clippy. Locked build/fmt pass.
Full source ERT against that binary: **1185/1185**, 0 unexpected, **128.51 s**.

## 2026-10-25 — One explicit HTTP replay authority

The HTTP builder now sets `reqwest::retry::never()` explicitly, independently of
the dependency's protocol-NACK defaults. The manifest minimum is the already
locked **0.12.28**; Cargo.lock and the enabled rustls/stream features did not
change. Verified against the locked source, versioned official builder docs and
`cargo tree --locked -e features -i reqwest`: today's build has neither http2 nor
http3, so this is defense against implicit policy/future feature unification,
NOT a claim that an unmetered replay was observed under the current build.

A real HTTP fixture reads the complete POST body, then either returns 503 or
drops ambiguously without response headers. A retained listening socket proves
no second connection was queued; the original typed failure must be preserved.
All **25 HTTP/live retry/circuit tests** and all-target strict Clippy pass. This
does not exercise an HTTP/2 NACK (that feature is not enabled). Last full native
and source ERT evidence remains the preceding typestate slice, above.

## 2026-10-25 — Checked indexing and an enforceable production gate

Two raw string range accesses in prompt-cache splitting are now `.get()` calls
in a small fallible boundary helper. Added UTF-8/repeated-marker, absent-marker,
empty-content and marker-at-start regressions; original cache contracts remain.

Enabling `clippy::indexing_slicing` also identified **18 production JSON index
writes**, beyond those ranges. Even where today's preceding `json!` constructs
an object, the panic-capable IndexMut form violates 01. These are now Map
construction/insertion (cache, stream accumulation, wire request/response and
safe error DTOs), or checked object access before attaching IPC budget/circuit
projections. Missing fields are still inserted; `get_mut` was not misused as an
insert operation. Unknown/null/false/absent usage semantics and safe errors stay
unchanged. No observed production panic is claimed just from the lint findings.

The library enables `deny(clippy::indexing_slicing)` under `not(test)`, so normal
library compilation in the strict all-target Clippy gate enforces this for all
production code. Unit/integration assertion fixtures retain their normal test
semantics; there is no production per-function allow, and unsafe remains forbid.
The first enabled production scan failed at all 18 writes; after correction the
strict all-target scan passes. Final frozen sources passed **211 native tests +
9 compile-fail**, locked build/fmt and strict Clippy. Full source ERT against
that final binary: **1185/1185**, 0 unexpected, **124.52 s**.

## 2026-10-25 — Typed command preparation / approval / running phases

`ipc/execution/state.rs` replaces the second `Option<Stage>` registry. Entries
are exhaustive variants of `Operation<Preparing>`, `Operation<Reviewing>` or
`Operation<Running>`. Preparing retains its actual blocking task until joined;
Reviewing retains the captured approval-ready command, correlation and receiver;
Running retains the actual owned run/job/reply. Terminal intent is in the common
owner and survives every transition, including pending polls and error results.

Mailbox methods accept only the proper concrete phase: prepare requires joined
Prepared data, launch requires ApprovalReady, collect requires Running. Internal
generic transition helpers are private; callers use only the allowed consuming
prepared/review/reviewed methods. API retry similarly exposes named valid phase
methods rather than a public generic phase switch. No state is temporarily None.
There is no new actor await, blocking IO, early release or name-derived authority.

Automatic review no longer matches tool names. `ExecutionGate::prepare` captures
the explicit executor `ToolSafetyLevel`, already checked against both registry
and command, in immutable ApprovalRequest metadata. Only SafeReadOnly skips UI;
arbitrary execution still needs the same exact approval gate. This removes a
policy smell, not evidence that today's fixed registry admitted an exploit.

A regression registers arbitrary executors named list_files/workspace_grep/
git_status: all remain ExecutesArbitraryCode and rejection never becomes an
execution grant. A compile-fail contract prevents relabeling a captured review.
All **212 native tests + 10 compile-fail**, locked build/fmt/strict Clippy pass.
The final binary's full source ERT: **1185/1185**, 0 unexpected, **123.99 s**.

## Audit boundary and remaining migration

The concrete findings recorded above have been addressed; this does not prove
the whole project's domain units, lifecycle and adapter boundaries correct.
High-level API/loop default native retry/circuit cutover and deletion of their
legacy Elisp engines remain open, as do the agent/run/history and external
application backend obligations in the approved roadmap. Continue auditing
their real consumers; do not treat passing tests or capabilities as a cutover.

HTTP source reference:
[versioned ClientBuilder docs](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html#method.retry).

This audit is incremental, not certification that the whole migrated tree now
conforms to every 01 directive. Do not relax 01 or remove legacy consumers until
their real native cutover and equivalent contract tests are complete.
