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
