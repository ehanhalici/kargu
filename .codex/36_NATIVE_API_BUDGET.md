# Native API accounting lifetime

## 2026-10-25 — Domain foundation, not yet consumer cutover

`application/budget/{domain,mod}.rs` defines a typed, single-writer meter.
Request/compaction counts and limits are distinct from tool steps and tokens.
The bounded default is 30 attempts and one logical compaction. Retries share
the attempt counter and do not re-charge a logical compaction. Refusal never
partially increments counters. Integer arithmetic is checked throughout.

`Budget<Open>::seal(self)` consumes admission rights. `Budget<Sealed>` can
collect already-issued move-only tickets, but has no admission method. Sealing
is not drain evidence; outstanding tickets retain the accounting lifetime.
Foreign tickets cannot change another meter. Compilation rejects re-admission
after seal and double collection of the same ticket.

Provider usage preserves absent/partial/known-zero distinctions. Only measured
input and output contribute to the sum; cache and reasoning subsets are not
added again. Overflow is terminal and never wraps or replaces the total with
zero. Unknown usage blocks future admission under an explicit token cap.
Pending measurement is temporary contention, not permanent exhaustion.

This observed-token cap is **not** a tokenizer reservation, provider spend
guarantee or monetary ceiling. G08 still needs reservation/pricing evidence.
No API budget capability is advertised at this foundation stage. The existing
Elisp consumer remains until native HTTP admission and real run binding are
connected and tested. Adding only a new native helper is not migration closure.

Evidence: 13 domain integration tests and two new compile-fail contracts pass;
all prior Rust tests pass, strict Clippy and formatting are warning-free.
No new dependencies, account requests or paid CLI calls.

## 2026-10-25 — Native HTTP admission and drain service

`ipc/api/` now contains the HTTP mailbox and its separate budget registry.
Capability `api_budget` exposes `api/budget/open`, `snapshot`, and `close`.
Open binds a fresh server-generated `BudgetId` to the exact native application
and service session; one live/draining budget per application is allowed.
Creating a budget while another unmetered HTTP attempt is active is refused.
The budget is an accounting lifetime, **not** a native agent claim or tool grant.

`api/request` optionally accepts a typed `budget: {budget_id, kind}` at the
scope envelope. Standalone callers without a budget remain explicit standalone
services; once an application has a budget, a generative POST cannot omit it.
GET cannot masquerade as a budgeted generation. Foreign/closed budget IDs fail
before IO; policy refusal and overlap do not debit another request. Each actual
attempt debits before network startup. Workers return observations only; the
mailbox consumes the charge once after join and the finite publication barrier.

`deadline_epoch_ms` is translated once to a monotonic deadline. Monotonic time
is sampled before wall time, so startup/IPC delay cannot extend the captured
deadline. Admission, active network work, and bounded final-body publication
honor it independently of per-attempt timers. Completed exact usage is retained
even if final-body delivery later fails. Unmeasured failure/cancellation remains
unknown, not free usage.

Close consumes ingress rights, cancels charged work and retains the registry
entry until actual join/charge collection. Only then does its reply contain
`status: closed` and the final detached budget snapshot. Canceling that close
waiter suppresses its reply but does not undo revocation or drain. No old ID is
resurrected. Application close/EOF/shutdown collect accounting as part of their
owned cleanup. Snapshot limits and totals are not editable admission authority.

Seven real stdio/socket tests cover pre-IO request limits, exact usage, foreign
scope/omission/GET rejection, socket drain-before-close-ack, stale-ID rejection,
deadline admission and active-IO cancellation, failed-attempt unknown usage,
and reclaiming capacity through 80 application lifetimes. Two mailbox tests
cover canceled close waiters and rejecting late budget creation over active IO.

Editor root-run binding and deletion of the old Elisp budget engine are the
next consumer slice. Until that is committed, ordinary editor runs do not yet
use this new capability. Retry/circuit ownership and native agent/history remain
open. These tests are concrete obligations, not a new TLA+ refinement proof.

## 2026-10-25 — Editor consumer cutover

The normal root run now constructs its budget intent before asynchronous
preparation, captures it in the execution context, and seals it before releasing
that context. Every logical request/retry shares that captured object. Standalone
API requests get their own logical-request accounting lifetime, sealed on finish
or cancel; they cannot accidentally seal their parent's shared run budget.

`bridge/budget.el` allocates one native ledger on the existing owned application
scope. Waiters coalesce and detach individually; late allocation after close is
drained. A replaced connection/scope cannot silently start a zero-valued ledger;
its old lease is revoked and the operation fails. Reentrant close revokes later
waiters. Native counters are projected before delivering the response, never
summed a second time; backwards/foreign/malformed projections are rejected.

The old Elisp debit/refusal/token-summing engine is deleted. `application/budget`
is only preference capture and a native display projection. Tool text is neither
an observed provider measurement nor an extra provider attempt, so a tool result
does not invent unknown billing usage. Session-wide UI usage/pricing remains
legacy and is not a second native run debit gate; its separate port remains open.
Compaction carries explicit logical kind; user/transport retries carry retry
kind and keep the same native budget rather than spending another compaction.
Healing/continuation are already charged by the shared physical-attempt gate;
their full algorithm/state ownership is still part of the native agent port.

Test relocation (not a module-boundary baseline change):

| Former Elisp policy contracts | Native/editor replacement |
| --- | --- |
| budget debit, limits, usage, unknown, seal | `api_budget.rs` (13 tests), including checked overflow and move-only tickets |
| transport initial/retry/usage and challenge deadline/compaction | `api_budget_stdio.rs` (7 tests), mailbox budget tests (2), real editor transport/root-run tests |
| coordinator ownership/preferences | retained projection/reset tests |
| late startup/epoch/reentrant close | new editor lease tests |

The removed private helper also accepted client-supplied multi-request/token
debits, although no production caller used its token argument. Native admission
charges exactly one actual attempt, and only provider observations update token
usage. This does **not** establish worst-case pre-request token reservation or
monetary equivalence: G08 reservation/pricing remains explicitly open. No old
helper test is cited as evidence that hard spending guarantees now exist.

Evidence: **1169/1169 full source ERT**, 0 unexpected, **125.26 s**; four detected
regressions were fixed with the late/synchronous callback assertions retained.
Root run -> stdio -> loopback HTTP -> one native charge -> seal/drain is real.
12 editor budget tests cover projection, epoch/late/reentrant ownership,
compaction kinds, old-core fail-closed, and normal root-run wiring. Native
baseline remains **170 tests + 4 compile-fail**. Touched warning-as-error byte
compilation and checkdoc pass; generated bytecode was removed.

This closes the optional-budget wiring gap, not the full migration: general
native foreground claims, tool consumers sharing that run, reservation/pricing,
retry/breaker, history/agent and external backends remain separate roadmap work.

## 2026-10-25 — Owner deadline is not an upstream timeout

Retry/breaker inspection found that the budget deadline and per-attempt deadline
both produced `deadline`. The compatibility error adapter consequently let an
owner-budget timeout reach the legacy provider-failure counter. They now have
distinct typed failures: `run_deadline` is local owner policy, while `deadline`
remains the physical attempt timer. Budget collection records its deadline
refusal immediately, including unknown usage, without waiting for another debit.
The local owner failure cannot trip the provider circuit or authorize retry.

The real editor -> Rust -> held loopback HTTP regression verifies one charged
attempt, exhausted-deadline projection, actual drain and zero provider failures.
All 13 focused editor budget tests, 20 native budget tests, locked build, strict
Clippy, touched bytecompile/checkdoc pass. Last full ERT before this correction
was 1169/1169; the newly added regression has separately passed. No claim of
complete retry/breaker migration follows from this targeted correction.
