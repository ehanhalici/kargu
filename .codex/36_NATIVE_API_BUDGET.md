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
