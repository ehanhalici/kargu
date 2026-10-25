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

## Remaining findings — not claimed fixed

- `ipc/api/retry.rs`: independent stage/charge/retry Options permit impossible
  resource combinations and enforce transitions with runtime CleanupFailed.
  Replace with consuming typed phases and phase-owned resources, retaining one
  mailbox writer, IO-worker observations and actual drain before slot release.
- `ipc/execution/mod.rs`: another `Option<Stage>` deserves the same ownership
  review after the API retry audit; passing tests are not typestate evidence.
- HTTP client's implicit reqwest protocol-NACK retry policy must be explicitly
  disabled so future feature unification cannot create a second replay authority.
  Locked 0.12.28 currently has neither http2 nor http3 enabled: do NOT report an
  observed hidden replay under today's features. Check the locked source and
  [versioned ClientBuilder docs](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html#method.retry).

This audit is incremental, not certification that the whole migrated tree now
conforms to every 01 directive. Do not relax 01 or remove legacy consumers until
their real native cutover and equivalent contract tests are complete.
