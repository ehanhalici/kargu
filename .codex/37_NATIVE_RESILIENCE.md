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
  This capture-loss obligation is resolved by the following typed IO slice.
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

## 2026-10-25 — Typed Retry-After IO capture

The real HTTP port now captures `RetryAfter` as parsed seconds, parsed date,
invalid metadata or a typed exceeded bound. Raw header text is not retained.
The retry policy consumes the same parsed value instead of parsing again.
Only canonical valid protocol values enter the temporary editor error DTO;
oversized/numeric-overflow values carry `retry_after_exceeded: true` rather than
vanishing as an absent header. Invalid short values cannot echo arbitrary text
or credentials into diagnostics. No sentinel string drives a control decision.

The legacy compatibility adapter refuses automatic replay for the exceeded
bound. Core DTO retains the original HTTP status; the temporary plz projection
treats that refusal as local policy so its old retry path cannot bypass the
typed limit. This is not full native retry cutover: legacy valid-value wait
clamping remains until the new policy/actor consumer replaces that engine.

One new real HTTP Rust test covers oversized/numeric-overflow/invalid secret
header values; one real editor -> core -> HTTP 503 test proves a single POST
and no scheduled early replay. The stream fixture now accepts explicit response
status/headers, without changing default success behavior.

Verification: **183 Rust tests + 5 compile-fail**, locked build/fmt/strict
Clippy; **1171/1171 full source ERT**, 0 unexpected, **124.03 s**, including
26 focused stream/budget tests. Touched bytecompile/checkdoc pass; generated
bytecode removed. A full Rust run first exposed the separate record-output
scheduling assumption; its corrected observed-cursor contract is committed and
explained in 26, and the complete Rust suite then passed.

## 2026-10-25 — Shared immutable attempt authority

The HTTP port can execute a borrowed captured request. The IPC worker retains
one `Arc<HttpRequest>` rather than consuming the authority on its first use.
No `Clone` implementation was added to the secret-bearing request or secret
type. A real two-connection test proves that reusing the same capture preserves
the exact request bytes, endpoint and authorization; no live preference lookup
or reparsing is involved. Each execution still performs exactly one physical
attempt: this prerequisite does not enable automatic native retries.

Verification: **184 Rust tests + 5 compile-fail**, locked build/fmt/strict
Clippy; **26/26 focused source stream/budget ERT**. The previous full source ERT
is **1171/1171**; it was not rerun for this borrowing-only slice. Existing run
deadline, cancellation and application-close tests pass unchanged.

## 2026-10-25 — Logical retention and non-charging preflight

Budget lifetime is retained by the logical API record, independently of its
current physical attempt ticket. Revocation checks use that captured identity;
budget collection additionally waits for all logical references to disappear.
Zero outstanding HTTP charges alone cannot acknowledge close while an operation
still owns a backoff/observer resource. A mailbox regression proves revoke,
retained zero-charge close, refusal and exactly-once release after logical drain.

The open domain budget exposes a non-charging preflight using the same gate as
`admit`; it is explicitly not a reservation. Final admission rechecks after any
wait/handoff. Tests prove no counter mutation and terminal expiry without a
fictional physical request. IPC admission returns a closed typed taxonomy,
including exact domain refusal, and maps to static RPC faults only at the wire
boundary. Future retry control need not branch on fault/status strings.

Verification: **187 Rust tests + 5 compile-fail**, locked build/fmt/strict
Clippy. The independently verified UI suite remains **1172/1172**. Native retry
and its observer/circuit consumers are still open; no retry capability advertised.

## 2026-10-25 — Native retry mailbox / owned observer handshake

`api/request` now accepts an explicit captured `retry` object with `policy`
and mandatory `observer` (`editor` or explicit headless `none`). The implemented
`api_retry` capability is advertised. Retry requires a generative request and
an owned native budget; malformed policy/observer, missing budget and GET
relabeling fail before charging or opening a socket. Omission remains exactly
one attempt, preserving raw service callers during UI cutover.

The parent actor alone chooses replay, advances attempt count and admits each
socket. IO executes one granted capture, reports usage/entropy, and joins before
another attempt. Bounded entropy observations are captured outside the mailbox;
an unavailable RNG cannot produce zero jitter and cannot override a policy stop
that needs no sample. Backoff and observer are separate cancellable worker
resources; their logical slot, immutable request Arc, original monotonic budget
deadline and budget identity stay retained through actual join. Budget preflight
is checked before waiting, after waiting and again after observation; admission
is still the authoritative debit. Unknown capped usage fails closed.

Editor observation is a bounded reverse `editor/api_retry` call correlated with
the exact forward request, owner scope and connection epoch. No payload/auth/URL
is exposed. Only a typed `{accepted: true}` response can grant the next attempt;
negative/malformed/unknown/late ACKs cannot authorize IO. The observer has its
own ten-second timeout capped by the original run deadline. Forward cancel,
budget/application close, shutdown and EOF revoke and join both waiting phases
before release. The finite event/join prefix barrier remains intact, including
partial deltas; queued egress also rechecks the budget deadline.

Evidence: nine real stdio/loopback tests cover identical two-attempt authority,
exact charges, observer-before-socket, negative/malformed/late ACKs, exhausted/
unknown budgets, server wait overflow, deadline during wait, visible partial
failure and both waiting phases under four teardown modes. A deterministic
entropy-failure test covers stop-before-draw semantics. **197 Rust tests + 5
compile-fail** passed; after readability-only function extraction, all **55
focused native tests** and strict Clippy pass again. Locked build/fmt pass.
Last independently verified full editor baseline is **1172/1172**.

This is a real native retry consumer, not yet the default GUI cutover: the
editor retry observer adapter is the next slice. Legacy Elisp retry/circuit
engines have not been removed prematurely. Native circuit registry/lease
composition with logical retry, UI error projection and full agent/run claims
remain open; no full API/backend migration claim follows.

## 2026-10-25 — Editor-owned retry observer port

The bridge now routes `editor/api_retry` only to the exact live forward waiter,
connection epoch, detached native application/session scope and source-buffer
lifetime. It rechecks ownership after callback reentry and ACKs false after
cancel, waiter replacement or consumer failure. A bounded per-waiter delivery
sequence prevents duplicate observer invocation; it is not a billing/retry policy
counter. Unknown/late observers receive no authority. No new singleton or timer
was added to Elisp.

The transport adapter accepts explicitly captured `:retry` policy and
`:on-retry` presentation callback, negotiates `api_retry`, projects the exact
native budget before notification and sends the owned ACK afterwards. Defaults
still preserve the existing high-level API while its remaining consumers are
being cut over. Six new editor tests include real two-socket success and real
callback cancellation followed by native budget drain, plus duplicate, foreign,
stale, failed/replaced waiter and detached-scope regressions.

Verification: **1178/1178 full source ERT**, 0 unexpected, **125.46 s**;
**197 Rust tests + 5 compile-fail** rerun on the committed native implementation.
Touched warning-as-error byte compilation and checkdoc pass; temporary bytecode
removed. No module-boundary baseline change or paid/external application turn.

Consumer audit found a second retry engine in `loop/machine.el`, which calls
the same legacy jitter helper. High-level API cutover must remove/replace that
consumer as well; simply deleting `api/retry.el` or enabling two retry engines
would not satisfy the plan. This remains an explicit next-step obligation.
