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

## Next consumers

Default plain/stream HTTP must capture native retry/circuit preferences once,
bind the existing owned observer before replay and surface typed terminal
failures without another local classification/replay decision. Then delete the
API retry timer/backoff/Retry-After engine and local circuit admission/counter/
probe engine, leaving preference/view/reset delivery only. Logical-request timer
fields and obsolete tests move only with their last consumers. No high-level
default cutover or legacy API-engine deletion is claimed by this first slice.
