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

## Remaining findings — not claimed fixed

- `ipc/execution/mod.rs`: another `Option<Stage>` deserves the same ownership
  review after the API retry audit; passing tests are not typestate evidence.
- `api/cache.rs`: two raw string range-index operations are safe by their
  preceding find today, but still violate 01's no-bare-index rule. Replace with
  checked access and preserve multibyte cache-boundary behavior.

HTTP source reference:
[versioned ClientBuilder docs](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html#method.retry).

This audit is incremental, not certification that the whole migrated tree now
conforms to every 01 directive. Do not relax 01 or remove legacy consumers until
their real native cutover and equivalent contract tests are complete.
