# Default API resilience cutover

## 2026-10-25 — Remove the second loop replay authority

Finding: after HTTP's own retry limit was exhausted, loop/machine classified
free-form terminal error text again, created another timer and issued a fresh
logical API request. That could multiply HTTP attempts and bypass a native
no-visible-replay or exhausted logical retry decision after the default cutover.

Deleted the loop's upstream-retry classification/event/handler, counter,
retry timer, timer cleanup and redundant counter reset. Terminal transport
errors now use the existing user recovery flow directly. Explicit user retry,
overflow compaction, tool-refusal recovery, empty-reply turns and stream retry
observers retain their distinct behavior. The HTTP engine is still legacy in
this first slice; its native replacement is the next step, not claimed done.

Configuration intentionally has one limit now: kargu-api-retry-max. The obsolete
kargu-loop-upstream-retries is a variable alias, not a second multiplier. Default
is still five transport retries. A user's old setting of the loop option now
sets that same transport limit; if both spellings are configured, normal Emacs
assignment order applies. No old default of three is copied over the API default.
No silent extra retries are retained merely for legacy compatibility.

## Contract mapping

- Existing manual retry/stop/timeout confirmation tests retain actual callback,
  reset, run-state and rendered prompt assertions; the deleted counter assertion
  is replaced with absence of loop retry accounting.
- The old circuit-open test now enters the actual response dispatch path, not
  the deleted private retry function; a cached circuit-admission read is forbidden.
- New terminal-error test covers 429/503/free-form upstream text and forbids any
  loop timer, request or retryability inference; all errors reach recovery.
- A compatibility test proves both option spellings share one transport limit.
- Fake-agent matrix now configures the real transport option, not a second loop
  counter. Native per-attempt charging/ACK/no-visible-replay contracts remain in
  api_retry_stdio and the GUI native-retry tests; assertions were not replaced by
  deleted-engine success expectations.

The abstract main TLA+ loop/classifier also drops MaxUpstreamRetries and its
counter. ModelReceiveUpstreamError always enters RECOVER. Bounds, all existing
safety invariants and unrelated transitions remain. Exhaustive rerun passed:
**537324349 generated / 63188083 distinct states, depth 45, 0 queued**, **7m42s**,
finished 2026-10-25 11:32:39 Europe/Istanbul. Fingerprint collision estimates:
optimistic .0016, actual fingerprints .0003. No invariant was weakened.
This is not a concrete native retry/circuit refinement proof.

Focused confirmation/alias ERT: **16/16**; touched Werror byte compilation passed
and its three generated .elc files were removed. **1187/1187 full ERT**,
0 unexpected, **165.14 s**, passed while the main TLC scan ran.
User shell.nix/07 edits remain untouched; no remote account/API/CLI turn ran.

## 2026-10-25 — Native terminal failure vocabulary

Added the closed Rust FailureCategory vocabulary and additive api_failure
capability. ApiError exhaustively produces a stable category in its snapshot;
the original code/status/Retry-After metadata remain separate and unchanged.
Logical run deadline is budget-exhausted with reason deadline, not a physical
HTTP timeout. Category labels are display projections, never replay/probe rights.
There is no string/status guessing policy in the editor in this slice: the
default editor consumer is not switched yet and ignores the additive field.

**215 native tests + 10 compile-fail**, locked build/fmt/strict Clippy passed.
After strengthening the live run-deadline wire assertion, **7/7 budget stdio**
and **16/16 native retry/circuit/connection GUI regressions** passed with the
rebuilt binary. Last full ERT remains the preceding loop slice (1187/1187),
not misreported as a fresh full run for this DTO addition.

## 2026-10-25 — Default plain/stream consumer cutover

Both default chat paths now open one native logical exchange with captured
retry/circuit preferences and their original generation/application/connection,
budget, debit category and UI consumer. Transport copies the policy DTO before
async startup; it never rereads preferences during replay. Zero Retry-After max
is explicit zero, not the timeout encoder's null. Rust validates all configured
bounds and the transient-status subset before a debit or socket. Every API
consumer requires api_failure; chat also requires api_retry/api_circuit and its
existing budget/wire/auth/request-policy capabilities before admission/startup.

The original UI retry hook runs on the captured owner before reverse ACK. An
owner/generation replacement or cancellation during notification refuses ACK;
there is no new Elisp POST/timer. Native already-published protection remains.
Terminal category/code/exact HTTP status/reason/partial metadata projects to the
existing Result error type in focused api/failure.el. Unknown/malformed category
fails closed as protocol-error, with no dynamic symbol interning or raw body.
IPC admission statuses remain distinct from upstream outcomes. No fake HTTP 400
or curl exit code is manufactured. Run deadline remains budget-exhausted rather
than timeout. Typed overflow/compaction timeout consumers use native categories.

Deleted the API replay scheduler, retry-post function, jitter/backoff timer,
Retry-After date/parser/clamping, HTTP/curl/prose classifiers, HTTP-200 error-text
replay branch, local circuit registry/counters/legacy mirrors/admission/cooling/
probe machinery and logical retry/stream timer fields/cleanup. Plain/stream
request delivery is consolidated; there is no local attempt counter. Removed
plz DTO construction, formatters, requires and package/setup/run dependency.
Editor circuit facade contains preferences, detached observation and explicit
owned reset only. Ping no longer predicts admission from a cached view.

Explicit model/compaction recovery waits for an issued native reset ACK before
opening a fresh request; duplicate ACK, reset failure and stale run are guarded.
With no observation there is nothing to reset: the fresh request still uses
native admission, never an editor grant. No reset starts/reconnects the core.

Behavior changes are intentional 01 compliance: full jitter has no 0.5 s floor;
Retry-After is a minimum, not a clamped early retry; 418 or arbitrary HTTP status
preferences are rejected; HTTP-200 free-form overload prose is protocol failure,
not replay authority; ambiguous connection/physical timeout and owner deadline
do not become automatic replays through the editor. Exact native HTTP status
and semantic kind are preserved even for partial/excess-wait outcomes.

### Test migration, not legacy-engine stubs

- Removed nine implementation-specific ERT tests for deleted API timers/local
  circuit transitions. Retry-After/date/clamp expectations are replaced by the
  strict native minimum/jitter tests in api/resilience/retry.rs, including
  full_jitter_includes_zero_and_upper_bound_without_a_half_second_floor and
  retry_after_seconds_and_http_date_are_minimums_not_clamped_early.
- Native circuit lifecycle/isolation/canary equivalents are actual stdio cases
  in tests/api_retry/circuit.rs: sole_probe_spans_real_backoff_and_observer_
  without_an_extra_charge; canceled_probe_is_neutral_and_can_be_reacquired_
  after_actual_join; same_model_namespace_shares_circuit_but_auth_endpoint_and_
  application_do_not; foreign_snapshot_reset_and_client_failures_cannot_heal_
  or_trip_another_circuit. These tests are retained, not weakened.
- New real default plain/stream tests prove two sockets, exactly one original
  UI observation before replay, two debits/observed usage, terminal-once, and
  zero second socket after observer cancellation plus acknowledged budget drain.
- Default terminal matrix covers 401/503/HTTP-200 error prose/typed overflow;
  run-budget test now asserts exact category/reason and native failures=0.
- Invalid retry limit/status/wait/circuit threshold/cooldown is rejected before
  the first socket/debit; async startup freezes all preferences, including zero.
- Real default circuit trip/refusal/reset proves no refused debit or socket.
  Missing each new capability forbids any application/budget/POST startup.
- Existing connection capture test now uses real core and two loopback sockets,
  not an Elisp retry-delay stub: changing config/provider policy between attempts
  cannot change endpoint, key, model or bytes. Scope/view/reset/owner tests now
  exercise native DTO projection, no local mutation. Manual reset ACK ordering,
  stale/duplicate/error cases are explicit ERT. Draft/history/storage/stale
  continuation tests remain. Module dependency budget was not refreshed.

First full source ERT passed **1183/1183**, 0 unexpected, **125.44 s**. After
additional frozen/invalid preference and manual ACK regressions, **8/8 focused**
passed. All **16 touched production files passed Werror byte compilation**;
their 16 generated elc artifacts were removed. Focused production checkdoc is
clean (environment OpenPGP autoload diagnostic only). Locked strict all-targets
Clippy passed again. Final source rerun after artifact removal passed
**1186/1186 full ERT**, 0 unexpected, **127.48 s** at 11:52:02 Europe/Istanbul.

The main bounded model result above belongs to the updated abstract loop,
not a concrete refinement proof of native retry or async reset ACK behavior.
No remote account/API or installed application model turn was invoked.

## Remaining consumers

Live model metadata normalization is still Elisp. Native agent run/claim,
history/compaction/healing/verification/persistence, hard pricing/reservation and
the four external application backends retain their own open acceptance gates.
This closes default HTTP resilience, not the whole migration. User 01 rules,
shell.nix and 07 edits were not changed.
