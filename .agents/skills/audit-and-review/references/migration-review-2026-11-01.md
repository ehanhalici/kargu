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

- Native edit_by_lsp now uses typed symbol selection and the shared native edit
  pipeline (see follow-up below). Public/standalone symbol edit/xref/context
  consumers still require cutover before todo 4.4b closes.
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
  read config files synchronously as a fallback. Refresh now requires the exact
  epoch, application/session scope and published configuration revision. Rust
  captures target/credential/wire from its config policy; caller URL/auth
  overrides and unowned refreshes are rejected. The existing native HTTP port
  performs discovery; stale config/session and exact RPC cancel prevent model
  publication. Bridge wrappers keep the application lease and cancel their exact
  request, without extracting credentials or reconnecting retired owners.
  Auth-source orchestration, custom registry/header settings, concurrent catalog
  publication ordering and authoritative native selection commit still need
  completion. The general public picker still uses the older owned pipeline.
  The binding user rule now explicitly requires removing its remaining Elisp
  orchestration; maintaining the old pipeline is migration debt, not closure.
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

## Native symbol edit follow-up

A native edit_by_lsp call now borrows one read_file_symbols execution step under
its actual model call. The existing delegated gate retains the same run lease,
uses native completion facts, and waits for real reverse-request quiescence.
It does not open another run or debit another model tool call. Only the fixed
helper pair is admitted; helper completion cannot become a parent history result.

Rust selects a unique definition in a complete, fresh tree and constructs a
native-only SymbolEditSelection witness (no Deserialize). Parent preparation
binds that witness to the actual model path/new_content and exact document UUID,
tick and language source. An editor-supplied range is not part of Begin. The
proposal splices the selected scalar range into the full captured RAM document;
identical text elsewhere is preserved, including Unicode and CRLF boundaries.

The editor observes raw provider/document metadata and uses the existing chunked
upload, review, transaction, journal and verified receipt adapters. It rechecks
the source at capture, before issue, and at actual handler entry after the native
issue RPC. Ownership guards remain valid after the edit's own tick changes.
The native batch path no longer borrows unrelated Elisp mode/directory authority;
the native run's captured scope controls it. The ordinary standalone path retains
its existing mode/revision guards.

Tests cover one-tool-budget actual imenu/provider/pipe edits, one canonical tool
result before the next model turn, stale/ambiguous/truncated lookup, forged
source/tick/text/wire range, duplicate CRLF/non-BMP splicing, and provider change
between native issuance and actual editor mutation. Journals in the fixture are
private temporary directories outside the workspace, matching the real policy.

This is a native-agent consumer slice. Public/standalone symbol edit and xref/
context migration, plus the remaining native run/UI/history integration, stay
open. Shared Rust module/host integration changes are still present in the
worktree; source commits do not imply the entire migration is committed or closed.

Symbol-edit validation: locked Rust **577 passed** across 54 suite results,
including 31 compile-fail documentation tests. Strict all-target Clippy and
changed Elisp Werror/check-parens pass. Existing exhaustive application (4,624),
edit preparation (319,746), and edit transaction (560) models passed. These are
lifecycle model checks, not proof of all unfinished sensor/context consumers.

Full source ERT for this worktree passed **1389/1389**. The validated source is
recorded in separate sensor/witness and editor-adapter commits. Common Rust
module/host exports and remaining native actor integration are not all committed
yet; these source commits do not assert a complete native backend at HEAD.

## Follow-up: Rust backend / Emacs frontend rule and native catalog capture

The user's 2026-11-01 instruction is now binding in todo.md and architecture
00/01: all business decisions and orchestration belong to Rust. Emacs supplies
UI events and editor primitives. Existing Elisp orchestration is migration debt.
Commit `12e2ca5` records this rule.

Commit `8596906` adds native configuration-to-model-request capture and shares
the existing catalog endpoint policy without creating a synthetic configuration
identity. Config/environment credentials, exact custom endpoint/query semantics,
public versus private discovery and provider wire/header policy are resolved in
Rust. The existing native HTTP implementation also rejects an oversized declared
body before attempting to read it. A private HEAD-based candidate containing only
this slice passed 25 tests and strict all-target Clippy independently of the
remaining working tree.

The working tree additionally binds model/refresh to the exact connection epoch,
application/session and config revision. Native configuration/read to model HTTP
to metadata publication passes a real pipe/loopback test. Changed config, closed
session, explicit RPC cancellation, foreign scope, stale revision and caller
URL/auth overrides cannot publish. The old duplicate reqwest fetch engine now
uses the existing native HTTP port. Bridge wrappers carry the exact lease and
RPC cancellation, do not extract keys or reconnect retired owners, survive an
unrelated agent Stop and cancel when the UI origin closes. These runtime/bridge
changes still depend on the uncommitted shared host/module integration; they are
not claimed as independently integrated at HEAD.

Current working-tree validation: 585 locked Rust tests including 31 compile-fail
docs; 1391/1391 full source ERT, followed by 6/6 focused bridge tests covering the
additional origin-close/agent-Stop case; strict all-target Clippy/fmt; changed
Elisp warning-as-error/check-parens; whitespace checks. Existing exhaustive TLC
models passed application (4624 distinct states) and connection (101708 distinct
states). These models do not prove a complete catalog consumer cutover.

Todo 8.2b remains open: native config/publication orchestration, auth-source as a
Rust-requested editor primitive, custom registry/header options, concurrent model
publication ordering, public picker/API-list-models cutover and deletion of the
remaining Elisp catalog orchestration/cache authority are still required.

## Follow-up: real conversations must not use the application service session

Native loop startup reused the application's passive service session for every
chat. Consequently two UI conversations under one application could share native
history, and replacing a UI conversation did not replace the native history
owner. A conversation lease now maps each explicit Emacs session to its own
Rust-created session ID, distinct from the service session used by config/model
ports. These are editor-to-backend handle mappings; Rust remains the history,
claim and drain authority.

The lease captures the application service identity, exact connection and epoch.
Cancelling one startup waiter preserves sibling waiters and the allocated chat
lease. Retiring a chat, killing its buffer or changing major mode revokes its
native conversation; a create response arriving after retirement is revoked on
its original connection. A changed epoch never receives an old close. Retired or
replaced leases cannot silently allocate another conversation. Close ACK means
session revocation, not actual worker collection or claim release.

A real stdio/local-provider test sends A1, B1 and A2 under one application. A2's
provider payload contains A1 and its answer plus A2; B1 contains no A messages.
A1/A2 use the same native session, B uses another, and neither uses the service
session. Killing A invalidates only A's native snapshot; B remains available.
Five additional controlled tests cover waiter cancellation, detached scope DTOs,
late create cleanup, replacement/epoch loss and mode-change retirement. Existing
10 native startup/terminal tests also pass. Full source ERT: 1398/1398. Changed
Elisp passes warning-as-error compilation, check-parens and whitespace checks.
No Rust or TLA+ source changed in this slice; TLC was not rerun, as requested.

Todo 5.9b closes only this conversation identity slice. Native history UI
paging/import, preparation-time native claim and final config receipt binding,
all mode/plan/background-tool consumers, legacy engine removal and task 6 remain
open. Inconsistent checked parent boxes 5.6/5.7/5.8 were reopened while preserving
the verified implementation/runtime subitems. Shared native Rust integration is
still present in the working tree and is not claimed as committed by this slice.

## Follow-up: native answers must reach the editor without a second history engine

A completed native prompt previously returned only status/accounting, and the
Elisp terminal adapter always supplied an empty answer. With streaming disabled,
no answer reached the chat renderer. The native terminal now identifies the last
committed answer message and exact history revision. Native message ingress
caches a display projection of assistant text/output_text blocks; its retained
bytes count against history capacity. Raw wire/provider/opaque content remains
unchanged. Reasoning, signatures, images and tool data cannot become display text
through a raw-JSON fallback.

The existing revision-bound history/read port now supports an explicit display
projection. UTF-8 page offsets and stale revisions are checked in Rust. The editor
only validates DTO identity/progress and assembles bounded text pages under the
original conversation lease. The terminal callback receives answer_text after
all pages succeed. Missing references, malformed/foreign/non-progressing pages,
revision loss, origin closure or epoch replacement cannot deliver partial text as
success. Both current page cancellation and prompt cleanup are bound to the
original connection epoch, including synchronous callback/request-ID races.

Real Rust pipe tests cover native display projection, opaque wire roundtrip,
Unicode/CRLF page boundaries, stale replacement and malformed visible blocks.
A real Emacs/native/local-provider test negotiates 1024-byte frames, retrieves an
answer larger than one frame with streaming disabled, and passes the complete
answer to the actual finish-status renderer once. Already streamed text is not
rendered a second time. The production formatter/parser remains in Rust.

Validation: 587 locked Rust tests including 31 compile-fail docs; 1405/1405 full
source ERT, followed by 25/25 focused history/conversation/startup tests after the
last prompt epoch-guard fix; strict all-target Clippy/fmt; changed Elisp
warning-as-error/check-parens/checkdoc; whitespace checks. TLA+ code did not
change and TLC was not rerun.

This slice commits the history component source and its native display/UI path.
The shared Rust module/actor/host integration and root Rust integration test
registration remain in the working tree; runtime counts above describe that
integrated working tree, not an independently complete native backend at HEAD.
Full transcript import/projection, early claim/config receipt, remaining tools,
mode/plan, legacy deletion and task 6 are still open. Todo 5.9c closes only the
explicit answer-display source/runtime slice.

## Follow-up: independent native core integration

The native agent/claim/history, typed registry/schema and sensor components are
now registered by the real library/application/IPC roots. Provider API accounting
and retry, parent-run OS/read/editor/edit dispatch, immutable tool catalog,
execution steps and actual resource collection share the existing actor and
supervisors. Native file capture/recheck uses a shared bounded raw RAM adapter;
normal ERT registration now includes native session/loop/file/edit/symbol tests.

The candidate was built from a clean HEAD archive, overlaid with the reviewed
native Rust integration and only the required editor/test adapters. It used its
own Cargo target directory and its own Emacs sources. No local crate artifacts
were shared across source roots. This independently integrated candidate passed
561 locked Rust tests across 54 suite results (including 31 compile-fail docs),
strict all-target Clippy/fmt, 1395/1395 full source ERT with the actual candidate
binary, and warning-as-error/check-parens for changed editor adapters/fixtures.

Task 7 persistence code is deliberately not part of this commit: its public RPCs
still perform blocking disk IO in the host and lack mandatory application/session
capabilities. Task 8's model/select only validates a choice while reporting
selected, without an authoritative native selection commit. The candidate omits
these unfinished RPC implementations and their future module/test registration.
A real stdio probe verified all five persistence methods and model/select return
MethodNotFound, create no disk artifacts and leave ping responsive. Owned native
provider/model discovery and the existing config policy ports remain available.

The original working files and unrelated staged changes are preserved. Native
integration is committed independently; the excluded persistence/selection work
remains visible as an uncommitted delta for its own audit. Counts above describe
the exact integration candidate, not a mix of its binary and the full working
tree. Previous notes that the shared native roots were uncommitted are historical
and superseded for this reviewed integration slice.

This does not close tasks 3–6: the agent is still opt-in; preparation-time UI
claim/config receipt, full native history/context import and projection, complete
LSP/Dape/plan/background consumers, compaction/healing/verification, hard monetary
reservation and legacy engine removal remain outstanding. No TLA+ code changed;
TLC was not rerun under the user's current test rule.
