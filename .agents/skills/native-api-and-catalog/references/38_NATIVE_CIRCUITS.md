# Owned native provider circuits

## 2026-10-25 — Live mailbox composition

`api/request.retry.circuit` optionally captures a validated circuit policy next
to retry classification and observer mode. Implemented capability: `api_circuit`.
Omission preserves the existing raw single-attempt/retry service profiles while
the high-level GUI consumers are migrated. Elisp circuit decisions are not yet
deleted or claimed cut over.

## Authority and registry lifetime

- One registry per connection actor, bounded to **256** captured circuits.
- Key: native application, immutable provider/endpoint/final-header authority,
  circuit policy and captured retry/failure classification. Model/body/wire
  revision itself is not a provider circuit namespace.
- Authority is a length-framed SHA-256 equality key, not an exported identity or
  password hash. It has no Debug/Serialize implementation. Raw URL/query/auth
  and even the digest never enter circuit projections, errors or logs.
- Opaque random circuit IDs are the only public correlation identities. Final
  header names/order normalize at the existing HTTP capture boundary; auth,
  tenant headers, provider and exact target changes cannot share a lease.
- Session closure does not erase application-owned upstream health. Application
  revocation retains active grants until collection, then removes idle entries
  before application-close acknowledgement.
- Capacity can evict only unused healthy Closed entries. Unhealthy, cooling,
  available/held probe and active entries are never evicted to bypass refusal.

## One logical outcome, many charged physical attempts

The actor acquires the regular/sole-probe lease before budget admission and
releases it neutrally if budget admission refuses. It retains that exact grant
through every network attempt, backoff and owned reverse observer. Intermediate
503s do not release/reacquire a probe or add multiple logical failure outcomes.
Every physical attempt still passes the same native meter independently.

Terminal classification consumes one move-only grant after actual worker join.
Successful transport/model structure is healthy; allowlisted upstream failures
use the captured classification. Owner cancel/deadline, local refusal, malformed
protocol/client responses and ambiguous TLS/connection errors are neutral.
Neutral probe cancellation makes a probe available without declaring healthy.
Registry release and budget release remain separate resource obligations.

For the circuit-enabled model profile, a successful HTTP status must also decode
to a canonical nonempty choices/message-object structure. HTTP 200 `{}` cannot
heal a probe. This is a transport-shape gate, not a claim that full native
history/tool identity/agent validation has already migrated. Raw service callers
without this model/circuit profile retain their previous response contract.

`ipc/api/admission.rs` owns capture -> admitted-resource construction; worker
inputs are one captured record. Network observation, parsing and bounded entropy
remain outside the writer; budget/circuit/publication state stays in the actor.

## Owned UI ports

- `api/circuit/snapshot`: `{scope, circuit_id? | provider?}`; no filter selects
  only that application's entries. Foreign IDs/scopes fail closed.
- `api/circuit/reset`: same selection, explicit revision invalidation. It does
  not replay IO, complete old operations or release their resource slots.
- Supplying both filters is invalid. Reset never affects another application.
- Final API results include the detached circuit view (opaque ID, provider,
  state, consecutive failures, remaining cooldown milliseconds, probe occupied).
  Snapshot does not acquire a probe; elapsed cooldown may display HalfOpen.
- A late pre-reset success/failure is inert even if a fresh regular request has
  completed in the meantime. The old operation still drains its own budget/slot.

## Evidence and remaining work

**206 Rust tests + 5 compile-fail**, locked build/fmt/strict Clippy pass. Nine
new contracts cover authority identity, bounded eviction/drain, and six live
stdio/HTTP circuit scenarios: probe across real wait/observer, blocked attempts
without charge, reset/late result, neutral cancel/reacquire, model/auth/target/app
isolation, foreign reset, client neutrality and malformed-model health refusal.
All earlier cancellation, deadline, EOF, application-close and fairness tests
also pass with the modular admission/worker changes.

**1178/1178 full source ERT**, 0 unexpected, **164.26 s**, rerun against this
native binary. The legacy main bounded TLC scan was started separately and was
still running at commit time: **no verdict yet**. It checks the existing
abstract loop/circuit model, not a refinement proof of this new Rust registry.
No formal model, module-boundary baseline or user shell/07 edit was changed.

Next: native circuit projection/reset adapter, high-level API default retry/
circuit cutover, and deletion of both legacy API and loop retry decision paths
with explicitly mapped consumer tests. General foreground native claims, full
agent/history, reservation/pricing and four external application backends remain
open roadmap obligations. No account/paid API/external application turn ran.

## 2026-10-25 — Detached GUI projection and explicit reset

`bridge/circuit.el` stores bounded display-only observations under the exact
live application/connection/scope. Native projections carry a connection-owned
`CircuitProjectionSequence`, distinct from lease revisions and failure counts.
The UI rejects old observations, including after display-cache eviction; reset
may legitimately decrease failures without allowing an older view to undo it.
Returned scope/view strings are detached. Replacement/closing owners cannot
retarget observations or hide a genuine native cancellation with a DTO error.

Transport captures optional `:circuit` alongside `:retry` and requires a native
application lease. Explicit reset uses that existing lease only: no core startup,
reconnect, local failure counter, admission decision or probe grant. The default
high-level API and loop retry engines have NOT yet been switched or deleted.

Seven new ERT contracts include real Emacs -> core -> HTTP 503 -> circuit refusal
without socket/debit -> explicit reset -> HTTP 200. **1185/1185 full source ERT**,
0 unexpected, **126.66 s**, passed against the native binary; focused capture/
circuit tests and touched Werror bytecompile/checkdoc also passed. Existing native
**206 tests + 5 compile-fail**, fmt/build/strict Clippy passed with the sequence
changes. No unrelated user shell.nix/07 change was staged.

The previously pending main bounded TLC regression completed successfully:
**718447752 generated / 84273208 distinct states, depth 45, 0 queued**, **10m27s**,
2026-10-25 08:28:02 Europe/Istanbul. This remains evidence about the unchanged
abstract loop model, NOT a concrete Rust circuit/retry refinement proof.

Next priority from the user's review: audit 01 strictly. In particular, replace
independent retry-stage/charge Options with resource-owning typed phases and
replace raw API page-byte sizes with a validated domain unit. Passing Clippy
alone does not establish these architecture contracts. Do not weaken 01.
