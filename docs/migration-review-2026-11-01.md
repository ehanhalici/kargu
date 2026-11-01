# Migration review — 2026-11-01

The user authorized review of all uncommitted changes, corrections, tests and
incremental commits. The sole task checklist is todo.md. This is an evidence
record, not a declaration that every changed file has been reviewed.

Initial inventory: 164 tracked changed paths, roughly 23,000 added lines,
plus new session/catalog sources and local scratch files. Staged and unstaged
changes were present. Scratch files read-only.txt, remaining.txt and symbol.el
are excluded from commits. No live provider accounts or user session files
were used in tests.

## Confirmed defects and corrections

- Budget preflight skipped monetary unknown-state checks whenever a token cap
  existed. A new failing regression confirmed the bug; independent ceiling
  checks fix it. Unknown usage and fractional micro-dollar charges no longer
  become exact zero/integer costs. The existing implementation is an observed
  spend ceiling, not a hard reservation; task 6.2 remains open. The budget
  slice passed 22 tests in an isolated worktree and was committed separately.
- Session save restarted journal sequence at one. Complete corrupt final lines
  were silently truncated. Recovery could modify a live writer's journal.
  Public storage APIs accepted traversal IDs. Four new regressions failed
  before fixes and pass afterward. Journal open now scans under flock, only
  incomplete non-newline tails are truncated, storage entry points validate
  IDs, reads are byte capped/no-follow, and exclusive publication uses
  persist_noclobber. Full saved checkpoints can recover without a snapshot.
  Focused session suite: 18 passed. These sources are still under review.
- New remote catalog fetch buffered the entire response before checking its
  parser limit, restarted the full timeout for the body, and silently omitted
  malformed authorization headers. Streaming byte limits, a common absolute
  deadline and explicit invalid-header failures were added, with three local
  HTTP regressions. No external network is required.
- Public catalog API bypassed the existing native metadata publication and
  captured credential/epoch lifecycle, and returned stale fallback models as
  successful refresh. The owned adapter to the existing Rust HTTP/metadata
  services was restored. Provider/model UI introduced a global cross-owner
  cache and a second selection writer. The existing native configuration
  projection path is retained, along with independent Company input fixes.
  Focused catalog/model/provider/selection acceptance: 75/75 passed.

## Remaining findings requiring implementation review

- Native edit_by_lsp is explicitly unavailable in edit/prepare/parent.rs.
- Native startup now uses the existing application lease, detaches snapshot
  connection/auth policy before yielding and cancels the exact prompt request.
  Native claim before configuration/credential/context preparation, canonical
  history import/projection, continuation UI and complete output rendering still
  need integration before native becomes the default agent.
- The complete Elisp agent FSM/tool consumers and original tests are retained
  because partial moved implementations lost repetition/continuation guards.
  Remove them only after their native consumers and acceptance are complete.
- LSP/Dape/context DTO foundations are not proof of complete consumer migration;
  standalone symbol/xref/context routes still need review.
- Session persistence RPCs in application/host.rs perform disk IO synchronously,
  permit missing epochs and do not bind storage to an application/session
  capability. Elisp storage/restore writers still exist. Delete/import/load
  locking, pinned directory identity, journal growth/compaction, protocol-ordered
  repair and snapshot/journal concurrency need completion before task 7 closes.
- Direct provider/model RPCs no longer borrow arbitrary application views or
  read config files synchronously as a fallback. Refresh uses only explicitly
  supplied auth; it no longer scavenges other applications/environment keys.
  Metadata publication is restricted to the captured application and live epoch;
  unscoped fetches return detached data. Unknown application IDs are rejected.
  Full session/config-revision/cancellation binding and authoritative native
  selection commit still require review. Public UI uses the existing owned
  pipeline rather than these incomplete replacement services.
- Monetary pricing helpers are not connected to actual native provider
  settlement. Hard pre-IO monetary reservation is absent; compaction/healing/
  verification still have Elisp orchestration.

## Validation record

Initial full ERT using a freshly built native binary: 1341 tests, 30 unexpected
failures, concentrated in the changed catalog and provider/model UI paths.
A previous invocation without the binary skipped native cases and is not
acceptance evidence. Full Rust/ERT and strict Clippy are being rerun after
corrections; final counts must be recorded before declaring closure. GUI/TLC
acceptance and review of all remaining paths have not been completed.

A verification-environment issue was found after the isolated worktree check:
sharing Cargo's target directory across the two source roots reused incompatible
local crate artifacts. The affected reruns are discarded. The isolated budget
result remains valid; the main crate artifacts are being rebuilt from a package
clean before final Rust/ERT acceptance. Dependencies and source files are kept.

Restoring the deleted loop test corpus exposed 14 real regressions in the
remaining Elisp backend: repetition guards, continuation caps, incomplete
responses and unsupported tools. The original machine/tools consumers and
boundary inventory are retained until native cutover is complete; the moved
partial implementations were removed from loop.el/ui.el. Focused loop/native
terminal suite passes 40/40. Native callback projection now distinguishes
completed/cancelled/timeout/rejected/failed/malformed replies; retired owners
are ignored and raw event payloads are no longer logged.

Clean rebuild validation: 573 Rust tests passed across 54 suite results
(including 31 compile-fail documentation tests). Strict all-target Clippy
passed with warnings/unwrap/expect/panic denied. The focused suites include
22 budget, 18 session storage and 3 catalog ingress tests. Full ERT including
restored loop coverage is running (1376 tests). These results establish the
checked behavior, not closure of the missing migration consumers listed above.

The 1376-test intermediate full ERT run ended with 7 failures: six fixtures
still targeting the discarded public catalog path and one already-loaded
boundary inventory. Credential/epoch lifecycle fixtures were restored alongside
the new direct RPC tests, with no live catalog network in the suite. Their
focused reruns passed 23/23 catalog tests and 49/49 module tests. Full current
source ERT must be rerun rather than treating these substitutions as one green
full-suite result. Exhaustive TLC passed budget (432 states), application
(4,624 states) and selection (640,440 states); these models do not establish the
missing hard monetary reservation or persistence RPC implementation.

## Final evidence for this review slice

- Current full source ERT with the native binary: **1379/1379 passed**, no
  unexpected results (2026-11-01 03:04 Europe/Istanbul). No tests were disabled
  to obtain this result. The original loop and credential lifecycle coverage
  is retained; new native terminal and direct RPC coverage is included.
- Current locked Rust suite: **574 passed across 54 suite results**, including
  **31 compile-fail documentation tests**. Strict all-target Clippy passes with
  warnings, unwrap, expect and panic denied; cargo fmt and git diff --check pass.
- Changed Elisp sources pass check-parens and Werror byte compilation. The one
  overlong session bridge docstring was corrected and its compilation rerun.
- Budget/application/selection TLC completed exhaustive scans successfully.
- GUI acceptance and complete review/implementation of all remaining migration
  consumers are outstanding. Most migration source changes remain uncommitted;
  the isolated budget slice and Company input behavior were committed separately.
  Green tests do not close tasks 3–8 or constitute review of every source path.

Reproduction uses the repository's Nix toolchain (`nix-shell --run ...`), locked
Cargo test/Clippy, and `KARGU_CORE_TEST_BINARY=$PWD/kargu-core/target/debug/kargu-core`
with the documented tests/run-tests.el batch runner. Compile artifacts were
written to a temporary directory and removed. The temporary budget worktree
was removed after its isolated acceptance run.

## Native startup ownership follow-up

The optional native frontend now requires a live execution and prepared connection.
It captures model, endpoint, provider, wire, tuning, auth intent, cache/stream,
retry and actual revision/turn-limit values before startup yields. It no longer
invents app/session identities, Bearer headers or provider/model defaults.
Unsupported diagnostic/xref reverse adapters are no longer advertised.

The new native-owner port acquires the captured application's existing native
lease, verifies it again before dispatch, and owns startup/scope waiters plus the
exact prompt request under one parent task. Stop uses rpc/cancel for that prompt;
it does not pass a service scope where session/abort requires a full RunScope.
Callbacks return through the captured execution; late acquisitions clean up
immediately. The scope is never taken from whichever application is current.

Regression sources cover retired owners, delayed startup after cancellation,
lease replacement, detached input, exact request cancellation and cancellation
before request-ID acquisition returns. Real pipe tests acquire actual app/run
identities and use a controlled local provider to check Rust-generated auth and
chat-path handling. No live account is used. Missing tuning is sent as an empty
policy object, preserving native defaults rather than invalid null.

History/UI projection, native pre-preparation claim and full continuation/context
consumers are still open. This does not complete todo 5.9 or enable native by default.

Backend selection is now solely the explicit native option. Missing binaries or
redefined API functions cannot cause a selected native run to fall back to Elisp.
The production constants that detected test mocks were removed. A dedicated
regression covers both missing availability and a redefined API sender.

Follow-up validation: full ERT **1386/1386** passed. After adding the explicit
backend-selection regression and removing mock-detection constants, the focused
native owner/snapshot group passed **11/11**. Werror compilation and check-parens
pass for the changed frontend/bridge/test files. Exhaustive TLC passed application
(4,624 states), connection (101,708 states), and transport (693 states).
No Rust source changed in this follow-up; the previous 574-test Rust acceptance
remains the baseline, not a newly claimed run. No GUI acceptance was performed.
