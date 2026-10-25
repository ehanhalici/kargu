# Native retry/circuit foundation

## 2026-10-25 — Domain implementation, not yet consumer cutover

`api/resilience/{domain,retry,breaker}.rs` provides captured typed policy,
bounded Full Jitter, allowlisted status classification, and move-only circuit
outcome leases. A circuit ID and revision bind both regular and probe leases;
a foreign same-revision lease cannot mutate another circuit. Trip/reset revoke
old completion rights. Half-open permits one probe; neutral cancellation makes
that probe available without declaring healthy or adding an upstream failure.

Retry settings are parsed once: 0–10 automatic retries, six supported transient
statuses (429/500/502/503/504/529), positive bounded base/cap, and bounded
Retry-After/cooldown intervals. Duplicate statuses, client/auth retry statuses,
invalid units and base > cap are refused, not silently coerced. New metadata
captures cannot mutate an existing policy. Only classified failures count;
owner deadline/cancel, client/protocol/resource and ambiguous connection/TLS
errors are neutral. Connection/TLS distinction still needs concrete IO evidence
before extending classification; no error-text matching is introduced.

Full Jitter samples the entire integer nanosecond window from zero through the
exponential ceiling. There is no inherited 0.5-second floor. Entropy uses the
system RNG, with bounded rejection sampling rather than biased modulo or a
zero-on-error fallback. Arithmetic is checked. Retry-After can supply seconds
or HTTP-date; malformed/past values do not invent a wait. Its valid minimum is
honored together with jitter. A wait above the configured ceiling, numeric
overflow or oversized captured value stops automatic retry instead of turning
into an earlier request.

No new retry capability is advertised and no retries are hidden inside the
existing HTTP worker. The live Elisp retry/circuit engines remain until the
mailbox, observer and UI consumers are cut over. This is not evidence that the
whole API migration or full native agent is complete.

## Required live-composition obligations

- Hold one circuit lease for the entire logical operation, including retry
  backoff and observer handoff. Do not release the sole probe between attempts.
  Intermediate attempts still share one logical terminal circuit observation.
- Each physical attempt must enter the existing native budget gate before IO.
  Backoff/observer cancellation cannot debit a request that never started.
- Preserve the finite body/event/join barrier, no replay after visible deltas,
  actual drain-before-release and sibling-owner isolation from 34/36.
- A retry observer can currently cancel before the legacy POST. Native cutover
  must preserve that ordering through a bounded owned handshake; notifying UI
  and immediately opening the socket would not be equivalent.
- Scope/bound the circuit registry by captured owner and endpoint/provider/auth
  authority. Reset/close must invalidate old completions, not replay effects.
- The current HTTP error capture drops Retry-After fields larger than 128
  bytes. Before live cutover, replace that loss with typed overflow handling;
  otherwise a very large valid delay could accidentally become early jitter.
  Do not expose raw oversized headers or synthesize sentinel error strings.
- Native result/error DTOs must replace the temporary plz/curl projection;
  delete legacy retry/breaker decisions only with matching live tests.

## Evidence and sources

12 new Rust tests (five deterministic retry tests, seven circuit/policy tests)
and one new compile-fail lease contract pass. They cover exact jitter endpoints,
bounded RNG failure, date/seconds/oversized waits, immutable policy validation,
single probe, neutral cancel, reset/open late results, and foreign lease IDs.
All prior Rust tests also pass, with locked build and strict Clippy. Application
registry/observer/real retry IO tests remain the next slice, not implied here.
Full verification: **182 Rust tests + 5 compile-fail** and **1170/1170 source
ERT**, 0 unexpected, **124.27 s**. No module-boundary baseline was changed.

Protocol/library evidence checked on 2026-10-25:

- [RFC 9110 §10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3):
  Retry-After accepts HTTP-date or nonnegative delay-seconds.
- [httpdate 1.0.3 parser](https://docs.rs/httpdate/1.0.3/httpdate/fn.parse_http_date.html):
  reuse the existing HTTP date parser, not a project-specific date grammar.
- [getrandom system RNG](https://docs.rs/getrandom/latest/getrandom/): use the
  ordinary supported backend. Exact 0.4.3 `u64` API was also checked in the local
  locked registry source. It was already transitive and is now an explicit
  dependency; only httpdate 1.0.3 adds a newly resolved package. No external app,
  login, account turn or paid API call was invoked.
