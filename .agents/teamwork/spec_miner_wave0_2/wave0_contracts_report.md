# Wave 0 Architecture Contracts Specification Mining Report

**Mining Agent**: `teamwork_preview_spec_miner_wave0_2`  
**Milestone**: Wave 0 Coordinator Contracts Baseline  
**Date**: 2026-10-21  
**Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2`  
**Target File**: `/home/emrehan/.emacs.local/kargu/architecture-contracts.md`  
**Authoritative Sources**:
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md`
- `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (§3, lines 62–102, and §4–8)
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md`
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md`
- `/home/emrehan/.emacs.local/kargu/kargu/contract/*.el`
- `/home/emrehan/.emacs.local/kargu/kargu/application/coordinator.el`
- `/home/emrehan/.emacs.local/kargu/kargu/async.el`
- `/home/emrehan/.emacs.local/kargu/kargu/files.el`
- `/home/emrehan/.emacs.local/kargu/tests/test-helpers.el`
- `/home/emrehan/.emacs.local/kargu/tests/test-modules.el`

---

## 1. Executive Summary

This report establishes the authoritative specification and complete draft for `architecture-contracts.md`, required by Wave 0 at the repository root.

Wave 0 is the foundational gating phase for the entire Kargu multi-wave transformation. Its primary purpose is to fix shared boundaries, canonical type definitions, result conventions, lifecycle state machines, and acceptance test fixtures before parallel workers in Waves 1 through 5 commence work.

### Core Architectural Invariants
1. **Single-Active-Run Invariant (ARCH-01 / ARCH-12)**: At any given moment, an Emacs application instance allows at most ONE active agent execution run. Concurrency among development workers in parallel worktrees does not alter Kargu's runtime execution policy. State is owned by an explicit `kargu-application` coordinator handle rather than global mutable variables.
2. **Pluggable & Detachable Adapters (ARCH-09)**: Feature modules (LSP, Dape debugger, search, bash, git, skills, webfetch, chat view, plan mode, diff engine, external agent backend) must be removable without breaking core offline headless loop execution. Missing adapters report explicit typed `unavailable` states rather than crashing or claiming false success. Missing security gates fail closed.
3. **Fail-Closed Security & Single-Use Captured Approvals (ARCH-02, ARCH-03, MOD-02)**: Continuation approvals for tools or file edits capture the exact source revision, environment hash, and policy revision. Captured tokens are single-use; replay or preapproved caches are strictly forbidden.
4. **Unified Budget Accounting & Hard Buffer Caps (DEEP-09, DEEP-12, MOD-04)**: All requests, retries, healing attempts, and compaction turns debit against a single run budget. Stream buffers, process output archives, and log buffers enforce hard byte/character caps on every write.
5. **No String Scraping for Control Decisions (ARCH-16)**: All status, error, and retry decisions must inspect canonical Result types (`kargu/contract/result.el`) with domain error symbols and effect plists. Parsing error strings to infer success or retryability is forbidden.

---

## 2. In-Depth Boundary Specifications for the 8 Core Boundaries

### Boundary 1: Application Contract
- **Purpose**: Manage single-run coordinator lifecycle, application claims, session epoch isolation, and ordered resets.
- **Producer**: Application Coordinator (`kargu/application/coordinator.el`, `kargu.el`).
- **Consumer**: Engine/Loop (`kargu/loop.el`), UI/Chat (`kargu/chat.el`), Plan Dispatcher (`kargu/plan/dispatch.el`), Reset service (`kargu/application/reset.el`).
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`.
  - *Optional*: Chat UI buffers, transient views (headless loop operates cleanly without UI).
- **Canonical Types**:
  - `kargu-application`: Struct holding `id`, `status` (`:idle`, `:starting`, `:requesting`, `:streaming`, `:executing-tool`, `:waiting-approval`, `:compacting`, `:verifying`, `:done`, `:stopped`, `:error`, `:limit`, `:pause`), `active-run`, `active-claim-token`, `active-request`, `session-id`, `generation`.
  - `kargu-application-claim`: Struct holding `token`, `app-id`, `run-id`, `mode`, `created-at`.
- **Validation Owner**: `kargu/application/coordinator.el`. Asserts `kargu-application-p` at boundary.
- **Lifecycle Events**:
  - *Creation*: `kargu-application-create` initializes an instance in `:idle` state.
  - *Claim*: `kargu-application-claim` validates that `active-run` is nil and `status` is `:idle`. On success, issues a unique claim token and advances generation.
  - *Release*: `kargu-application-release` validates that the presented claim token matches `active-claim-token`. Releases claim, clears active request, and returns status to `:idle`.
  - *Ordered Reset*: Sequentially cancels active run -> flushes history -> resets circuit breakers -> resets coordinator state -> notifies passive view observers. Foreign sessions and runs are untouched.
- **Invariants**:
  - Claim before view notification: Claim must be granted before view/buffer is updated.
  - Releasing a claim only releases that exact claim; foreign tokens are rejected.
  - Dual-application isolation: Two application fixtures never share or mutate each other's state.

### Boundary 2: Async Scope Contract
- **Purpose**: Manage asynchronous tasks, cancellation trees, execution deadlines, and single-delivery callbacks.
- **Producer**: Async Task Manager (`kargu/async.el`).
- **Consumer**: Transport HTTP Client (`kargu/api/http.el`), Credential Worker (`kargu/config/worker.el`), Process Runner (`kargu/tools/process.el`), Edit Service (`kargu/edit.el`), Dape Adapter (`kargu/tools/dape/lifecycle.el`).
- **Dependencies**:
  - *Required*: `cl-lib`, `kargu/core/log.el`.
  - *Optional*: None.
- **Canonical Types**:
  - `kargu-async-task`: Struct holding `id`, `state` (`:pending`, `:done`, `:cancelled`), `callback`, `timer`, `owner`, `valid-p`, `cancel` (cleanup thunk), `parent`, `buffer`, `deadline`.
- **Validation Owner**: `kargu/async.el`.
- **Lifecycle Events**:
  - *Creation & Setup Barrier*: `kargu-async-start` fully constructs and registers the task before any asynchronous work or callback can run. Early callbacks cannot bypass the setup barrier.
  - *Hierarchical Cancellation*: `kargu-async-cancel` cascades cancellation to all child tasks recursively, runs cleanup thunks under `unwind-protect`, and cancels timers.
  - *Three-Stage Separation*: Cancellation request != Process exit != Terminal callback delivery.
  - *Single Delivery*: `kargu-async-finish` invokes callback exactly once. Duplicate deliveries are dropped.
- **Invariants**:
  - Structured tree cancellation: Parent cancellation cascades downward; child cancellation never affects parent or siblings.
  - Origin buffer protection: If origin buffer is killed, task cancels cleanly without crashing.

### Boundary 3: Edit Service Contract
- **Purpose**: Unified filesystem mutation engine with source revision verification, review tables, and atomic rollback.
- **Producer**: Edit Service (`kargu/edit.el`, `kargu/tools/diff.el`, `kargu/tools/diff/context.el`).
- **Consumer**: Tool Execution Gate (`kargu/tools/execution.el`), Native Loop (`kargu/loop.el`), Plan Dispatcher (`kargu/plan/dispatch.el`), LSP Symbol Editor (`kargu/tools/lsp/symbols.el`).
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/result.el`, `kargu-file-current-revision` (from `kargu/files.el`).
  - *Optional*: Ediff review adapter, Git command-line client.
- **Canonical Types**:
  - `kargu-file-revision`: Struct holding `inode`, `device`, `bytes`, `mtime`.
  - `kargu-edit-service`: Struct holding `service-id`, `root`, `snapshots`, `changes`, `reviews`, `active-plans`, `policy-revision`.
  - `kargu-edit-plan`: Struct holding `plan-id`, `path`, `kind`, `proposed-content`, `expected-revision`, `policy-revision`, `session-id`.
  - `kargu-edit-outcome`: Struct holding `plan-id`, `path`, `status` (`:applied`, `:staged`, `:conflict`, `:partial`, `:unavailable`), `post-revision`, `hunks-applied`, `hunks-total`, `message`.
- **Validation Owner**: `kargu/tools/diff/context.el` and `kargu/edit.el`.
- **Lifecycle Events**:
  - *Plan Capture*: Captures current disk revision via `kargu-file-current-revision`, active session ID, and policy revision.
  - *Approval Re-Validation (ARCH-03)*: When user approves, document revision is re-validated against current disk revision. If changed, approval is invalidated, transaction aborts with `:conflict`.
  - *Execution*: Applies block, symbol, or isolated `git apply`.
  - *Save-Hook Reconciliation*: Reconciles post-save modifications into `post-revision`.
  - *Rollback on Abort*: On Stop or conflict, rolls back uncommitted hunks. If foreign writer modified target, rollback halts and reports conflict without clobbering external changes.
- **Invariants**:
  - ARCH-04: Block, symbol, and Unified Diff converge on identical transaction semantics and outcome records.
  - User index protection: Never touches `.git/index` or runs `git apply --cached`.

### Boundary 4: Connection Snapshot Contract
- **Purpose**: Bind provider, model, endpoint, protocol capability, config revision, and credentials into an immutable snapshot (CONFIG-01, DEEP-14).
- **Producer**: Config & Connection Resolver (`kargu/config/connection.el`, `kargu/config/worker.el`).
- **Consumer**: Transport HTTP Client (`kargu/api/http.el`), Circuit Breaker (`kargu/api/circuit.el`), Catalog Service (`kargu/providers/catalog.el`), Egress Gate (`kargu/permission/policy.el`).
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`.
  - *Optional*: `auth-source` (accessed strictly via nonblocking background worker; synchronous UI invocation prohibited).
- **Canonical Types**:
  - `kargu-connection-snapshot`: Immutable struct holding `id`, `provider`, `model`, `endpoint`, `wire-format`, `capabilities`, `config-revision`, `credential-scope`, `created-at`.
- **Validation Owner**: `kargu/config/connection.el`.
- **Lifecycle Events**:
  - *Async Secret Discovery (CONFIG-01)*: Nonblocking resolution in worker process; interactive prompts return `:auth-unavailable`.
  - *Snapshot Freeze*: Once validated, connection snapshot slots are read-only.
  - *Retry Preservation*: Retries for a logical request reuse identical connection snapshot.
  - *Teardown*: Credential memory is wiped upon completion or reset.
- **Invariants**:
  - Zero secret leakage (DEEP-14): Secrets NEVER appear in process `argv`, log files, transcript buffers, or session history.
  - Cross-origin isolation: Redirects to a different origin strip authorization headers immediately.

### Boundary 5: Tool Registry & Execution Gate Contract
- **Purpose**: Single gate for tool registration, parameter schema validation, mode checks, single-use permission approvals, output budgeting, and async execution (MOD-02, ARCH-02, ARCH-03, ARCH-09).
- **Producer**: Composition Root / Tool Registry (`kargu/tools/registry.el`, `kargu/tools/execution.el`).
- **Consumer**: Headless Engine (`kargu/loop/tools.el`), Direct API caller (`kargu/api/tools.el`), Interactive Chat UI.
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/async.el`, `kargu/permission/guards.el`.
  - *Optional*: Feature adapters (LSP, Dape, Bash, Git, Diff, Search, Webfetch).
- **Canonical Types**:
  - `kargu-tool-definition`: Struct holding `name`, `description`, `parameters`, `executor`, `policy`.
  - `kargu-tool-execution-context`: Struct holding `context-id`, `app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, `policy-revision`.
  - `kargu-tool-approval`: Struct holding `token-id`, `tool-name`, `args-hash`, `root`, `policy-revision`, `claimed-p`.
- **Validation Owner**: Tool Execution Gate (`kargu/tools/execution.el`).
- **Lifecycle Events**:
  - *Gate Entry*: Single gate validates canonical name, tool presence, mode compatibility, parameter JSON schema, policy availability, and single-use approval.
  - *Execution*: Asynchronous invocation returning cancel handle.
  - *Output Bounding*: Truncates to output limit; archives excess in project buffer `*kargu-output-N*` within byte/buffer quotas.
  - *Active Unload*: Drains or cancels running tasks before detaching tool code.
- **Invariants**:
  - Single gate for direct and alias invocations.
  - Single-use captured approvals (ARCH-03): Replay attempts rejected; preapproved caches prohibited.
  - Fail-closed: Missing permission adapter rejects execution.

### Boundary 6: Budget Accounting Contract
- **Purpose**: Single unified debit gate for all operations in an agent run (requests, retries, healing, compaction) (DEEP-09).
- **Producer**: Application Run Budget Manager (`kargu/application/budget.el`).
- **Consumer**: Headless Loop (`kargu/loop.el`), Transport Client (`kargu/api/http.el`, `kargu/api/retry.el`), Compactor (`kargu/loop/compact.el`), Healer (`kargu/loop/heal.el`).
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/result.el`.
  - *Optional*: None.
- **Canonical Types**:
  - `kargu-run-budget`: Struct holding `run-id`, `max-requests`, `requests-spent`, `deadline`, `max-tokens`, `tokens-spent`, `tokens-unknown-p`, `status` (`:ok`, `:exhausted-requests`, `:exhausted-deadline`, `:exhausted-tokens`).
- **Validation Owner**: `kargu/application/budget.el`.
- **Lifecycle Events**:
  - *Creation*: Bound to `kargu-application` at run claim time.
  - *Debit Gate*: Asserts request count and deadline limits prior to dispatching any HTTP attempt, retry, compaction, or tool healing turn.
  - *Usage Recording*: Updates token totals upon response delivery; omitted token counts set `tokens-unknown-p = t` (never coerced to 0).
  - *Terminal State*: Seals budget on exhaustion or run completion.
- **Invariants**:
  - Unified debit gate (DEEP-09): All turn types debit from the same budget.
  - Unknown usage integrity: Missing token metrics are recorded as unknown, never free.
  - Subtask immunity: Child scopes cannot reset parent run budget.
  - Single compaction default: Run permits at most 1 compaction turn by default.

### Boundary 7: Events Contract
- **Purpose**: Decouple passive observable notifications from decision-requiring control requests (MOD-01, ARCH-06, ARCH-07).
- **Producer**: Headless Loop Engine (`kargu/loop.el`), Transport SSE Parser (`kargu/api/stream.el`), Process Runner (`kargu/tools/process.el`).
- **Consumer**: Chat UI View (`kargu/chat/stream.el`), Passive Observers (`kargu/core/observers.el`), Log Redactor (`kargu/core/log.el`).
- **Dependencies**:
  - *Required*: `kargu/contract/assert.el`, `kargu/contract/types.el`.
  - *Optional*: Chat UI, transcript buffers.
- **Canonical Types**:
  - `kargu-event-id`: Struct holding `run-id`, `session-id`, `request-id`, `sequence-no`, `timestamp`.
  - `kargu-passive-event`: Struct holding `id`, `type` (`:stream-chunk`, `:turn-start`, `:tool-start`, `:tool-finish`, `:run-finish`), `payload`.
  - `kargu-control-request`: Struct holding `id`, `kind` (`:confirmation`, `:plan-approval`), `prompt`, `default-action` (`:reject`, `:stop`, `:cancel`), `on-decision`, `timeout`.
- **Validation Owner**: Loop Engine / Event Dispatcher (`kargu/loop/machine.el`).
- **Lifecycle Events**:
  - *Emission*: Increments sequence number monotonically per run.
  - *Observer Dispatch*: Handled under `condition-case-unless-debug`; observer failures never crash engine.
  - *Single Terminal Event*: Exactly one `:run-finish` event emitted per run.
  - *Control Request Fallback*: Headless environment immediately evaluates `default-action` (`:reject` or `:stop`).
- **Invariants**:
  - Passive events are immutable; observers cannot modify state.
  - Control requests cannot default to approval.
  - View updates use bounded coalesced queues; view lag cannot block engine.

### Boundary 8: Results Contract
- **Purpose**: Canonical Railway-Oriented Programming Result algebraic data type with domain error codes and effect status descriptors (ARCH-16).
- **Producer**: All core modules and adapters (`kargu/contract/result.el`, `kargu/api/http.el`, `kargu/edit.el`, `kargu/permission.el`, `kargu/tools/execution.el`).
- **Consumer**: Error handlers, retry dispatchers, self-healing loop, ERT assertions.
- **Dependencies**:
  - *Required*: `kargu/contract/result.el`. Zero external dependencies.
  - *Optional*: None.
- **Canonical Types**:
  - `kargu-result-ok`: Struct holding `value`. Constructor: `kargu-ok`. Predicate: `kargu-ok-p`. Accessor: `kargu-result-value`.
  - `kargu-result-err`: Struct holding `message`, `code`, `data`. Constructor: `kargu-err`. Predicate: `kargu-err-p`.
  - Domain error symbols (see Section 8.5 of `architecture-contracts.md`).
  - Effect status descriptor: `(:side-effect :none | :partial | :committed | :unknown)`.
- **Validation Owner**: `kargu/contract/result.el` and boundary validators.
- **Invariants**:
  - ARCH-16: `kargu/contract/result.el` is the sole Result framework in the codebase.
  - No string parsing: Retry and healing decisions MUST inspect `code` and `data` properties, NEVER match against `message` string.
  - Side-effect tracking on retry: Errors carrying `:side-effect :unknown` or `:committed` prohibit blind automatic retries.

---

## 3. Wave 0 Acceptance Fixtures & Verification Criteria

1. **Dual-Application Isolation Fixture**:
   - Two distinct `kargu-application` coordinator instances (`app-1` and `app-2`) operate independently within the same Emacs process.
   - Claiming `app-1` sets status to `:starting` with a valid claim token. `app-2` remains `:idle`.
   - Resetting `app-1` clears its active claim without disturbing `app-2`.
2. **Single-Active-Run Rejection**:
   - First claim on `app` succeeds with `(kargu-ok claim-1)`.
   - Second concurrent claim on `app` is rejected with `(kargu-err "Application is busy with an active run" :busy ...)`.
   - Only `claim-1` can release `app`.
3. **Pluggable Independent Contract Loading**:
   - `(require 'kargu/contract)` evaluates cleanly in batch `emacs -Q`.
   - Runtime features (`kargu/core`, `kargu/state`, `kargu/chat`, `kargu/loop`, `kargu/tools/*`) are NOT loaded.
   - Zero state stores, tool registries, or session contexts are allocated upon contract loading.
4. **Public File Revision Reader Bootstrap**:
   - `kargu-file-current-revision` is exposed in `kargu/files.el` as a public API returning a verified `kargu-file-revision` struct.
   - Package B (Wave 1) consumes `kargu-file-current-revision` directly, eliminating private cross-module calls (`kargu-file--file-revision`).

---

## 4. Comprehensive Features Discovered Table

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|---|---|---|---|---|---|---|
| 1 | Wave 0 | Coordinator Contract Framework | Core type definitions, assertions, constants, and canonical result structs establishing modular boundaries | Elisp definitions in `kargu/contract/*.el` | Validated contract types and result structures | Signals error on contract assertion failure | `parallel-plan.md` §3 |
| 2 | Wave 0 | Public Revision Reader Bootstrap | Publicly exposes `kargu-file-current-revision` in `kargu/files.el` to eliminate private calls from Package B | File path string | `kargu-file-revision` struct (`inode device bytes mtime`) | Signals error if file disappears or unreadable | `parallel-plan.md` §3, `kargu/files.el:142` |
| 3 | Wave 1 / A | Owned Application Context | Explicit `kargu-application` struct managing claim, transition, and release lifecycle per Emacs instance | Application handle, session handle, run request | Claim token, status record | Rejects double claims with `:busy`; rejects invalid claim release with `:stale-claim` | `parallel-plan.md` §4 (A), `todo.md` ARCH-01/12 |
| 4 | Wave 1 / A | Async Task Ownership & Scope | Structured async cancellation tree binding tasks to owners with deadlines and cleanup stacks | Parent owner, task callback, deadline | Async task handle (`kargu-async-task`) | Cancel triggers teardown; early completion cannot skip setup | `parallel-plan.md` §4 (A), `todo.md` ARCH-17, `kargu/async.el` |
| 5 | Wave 1 / A | Run Budget Core | Unified accounting of request counts, deadlines, and token limits per run | Debit request (type, count, tokens) | Approved debit or `:budget-exhausted` error | Rejects requests exceeding budget; unknown usage tracked as `:unknown` | `parallel-plan.md` §4 (A), `todo.md` DEEP-09 |
| 6 | Wave 1 / B | Single-Owned Edit Service | Encapsulated edit transaction service managing pre-state snapshots, review tables, and commit hooks | Edit plan (block, symbol, or patch), buffer/path | Transaction outcome (`applied`, `staged`, `conflict`, `partial`) | Rejects stale revisions; handles rollback conflicts | `parallel-plan.md` §4 (B), `todo.md` ARCH-04, `kargu/edit.el` |
| 7 | Wave 1 / B | Frozen Approval & Transaction Plan | Captures source revision, session/run epoch, and policy revision into an immutable review plan | Document snapshot, proposed changes | Typed review token | Re-validates upon approval; invalidates with `:conflict` if disk changed | `parallel-plan.md` §4 (B), `todo.md` ARCH-03 |
| 8 | Wave 1 / B | Isolated Unified Diff Engine | Applies unified diffs in temporary isolated directory using `git apply` without touching user index | Patch string, target files | Staged changes for review | Rejects malformed patches, rejects out-of-scope targets | `parallel-plan.md` §4 (B), `todo.md` ARCH-04 |
| 9 | Wave 1 / C | Nonblocking Credential Discovery | Resolves API keys and credentials in cancellable worker process without blocking Emacs UI thread | Provider name, config scope | Redacted credential token or `:auth-unavailable` | Timeout/cancel terminates worker; no plaintext leaks | `parallel-plan.md` §4 (C), `todo.md` CONFIG-01, `kargu/config/key.el` |
| 10 | Wave 1 / C | Immutable Connection Snapshot | Bundles provider, model, endpoint, protocol version, and credential scope into a single immutable record | Config settings, credential token | Connection snapshot handle (`kargu-connection-snapshot`) | Fails if required endpoint is invalid or TLS unverifiable | `parallel-plan.md` §4 (C), `todo.md` DEEP-14 |
| 11 | Wave 2 / D | Unified Tool Execution Gate | Single gate for tool registry, schema validation, permissions, budget checking, and execution | Tool name, arguments, execution context | Typed execution result or async handle | Denies unregistered, unauthorized, or budget-exceeded calls | `parallel-plan.md` §5 (D), `todo.md` MOD-02, `kargu/api/tools.el` |
| 12 | Wave 2 / D | Single-Use Captured Approval | Bound continuation for tool execution tied to root, environment, and config revision | User confirmation response, approval token | One-time execution authorization | Replay attempts rejected with `:approval-stale`; invalidated on env change | `parallel-plan.md` §5 (D), `todo.md` ARCH-03, `kargu/confirm.el` |
| 13 | Wave 2 / D | Dynamic Tool Unload / Drain | Safely drains running tasks and cancels resources when a tool is disabled or unregistered | Unregister request, tool identifier | Unload confirmation | Drains tasks before unbinding code; prevents dangling callbacks | `parallel-plan.md` §5 (D), `todo.md` ARCH-09 |
| 14 | Wave 2 / E | Loop-Independent HTTP Transport | Asynchronous HTTP/SSE transport decoupled from agent loop and UI state | Request parameters, connection snapshot | SSE event stream, response record | Circuit opens on repeated failures; timeouts cancel requests | `parallel-plan.md` §5 (E), `todo.md` MOD-04 |
| 15 | Wave 2 / E | Transport Backpressure & Bounds | Enforces buffer limits on SSE events, incomplete lines, and tool-call accumulations | Inbound byte stream | Bounded parsed chunks | Raises terminal error on limit breach; drains event loop | `parallel-plan.md` §5 (E), `todo.md` DEEP-12 |
| 16 | Wave 2 / E | Cross-Origin Credential Guard | Strict check preventing authorization headers from following HTTP redirects to different origins | Redirect URI, request headers | Filtered headers | Strips sensitive headers on cross-origin redirects | `parallel-plan.md` §5 (E), `todo.md` DEEP-14 |
| 17 | Wave 2 / F | Process & Job Lifecycle Service | Explicit service owning child process tables, signal groups, and bounded tail outputs | Command, argv, working directory, timeout | Job handle, stdout/stderr stream | Escalates from graceful SIGTERM to SIGKILL on timeout | `parallel-plan.md` §5 (F), `todo.md` DEEP-05 |
| 18 | Wave 2 / F | Process Stress Anomaly Isolation | Deterministic harness to isolate process cancellation and stderr drain timing anomalies | Process stress test suite, concurrency parameters | Execution trace and timing logs | Identifies root cause of stderr EOF races (RISK-01) | `parallel-plan.md` §5 (F), `todo.md` RISK-01 |
| 19 | Wave 3 / G | Headless Agent Execution Loop | Turn-based agent execution machine operating purely on application and transport ports | Context handle, initial prompt | Terminal execution report (`:done`, `:stopped`, `:error`, `:limit`) | Handles loop errors, budget exhaustion, or user Stop | `parallel-plan.md` §6 (G), `todo.md` MOD-01, `kargu/loop/machine.el` |
| 20 | Wave 3 / G | History Store & Protocol Wall | Queue maintaining write-time invariants and validating all messages before wire transmission | User/assistant messages, tool results | Validated wire-ready payload | Sanitizes malformed tool call pairs; repairs broken turns | `parallel-plan.md` §6 (G), `todo.md` ARCH-07, `kargu/contract/history.el` |
| 21 | Wave 3 / G | Unified Debit Accounting | Shared debiting across loop turns, retries, healing attempts, and compaction | Debit event, turn type | Updated budget status | Halts loop if overall budget is exhausted | `parallel-plan.md` §6 (G), `todo.md` DEEP-09 |
| 22 | Wave 3 / H | Decoupled View & Stream Service | Renders streaming agent transcripts into Emacs buffers using coalesced rendering queues | Stream chunks, view handle | Updated buffer display | Preserves draft, point position, and user narrowing | `parallel-plan.md` §6 (H), `todo.md` ARCH-06 |
| 23 | Wave 3 / H | Owned Metadata & Catalog Service | Caches provider models, dynamic capabilities, and refusal metadata per connection snapshot | Provider connection snapshot | Model catalog, capability descriptor | Differentiates between disabled provider vs empty catalog | `parallel-plan.md` §6 (H), `todo.md` ARCH-19 |
| 24 | Wave 3 / H | Plan Dispatcher Port | Manages preparation, user editing, and dispatching of structured task plans | Task prompt, plan context | Executable plan record | Rejects concurrent plan claims; protects user edits | `parallel-plan.md` §6 (H), `todo.md` MOD-06 |
| 25 | Wave 3 / I | Boundary Log Redaction | Proactive redaction of credentials, bearer tokens, and structured secrets before logging | Log message, metadata | Redacted log entry | Fails closed on redactor error (never writes raw text) | `parallel-plan.md` §6 (I), `todo.md` DEEP-06 |
| 26 | Wave 3 / I | Strict Retention Cap | Enforces fixed byte and line limits on logging buffers immediately after every write | Buffer write event, retention limit | Trimmed log buffer | Trims oldest entries while preserving valid Unicode points | `parallel-plan.md` §6 (I), `todo.md` DEEP-07 |
| 27 | Wave 4 / J | LSP Diagnostic Snapshot Port | Captures checker, server, session, and source revisions into immutable diagnostic snapshots | Buffer, file path, LSP client | Typed diagnostic snapshot | Returns `unavailable` if LSP server is disconnected | `parallel-plan.md` §7 (J), `todo.md` DEEP-01 |
| 28 | Wave 4 / J | Exact Coordinate Conversion | Converts between LSP UTF-16/32 character offsets and Emacs buffer points on widened buffers | LSP position, buffer text | Exact Emacs buffer point | Returns `nil` on invalid surrogate or out-of-range position | `parallel-plan.md` §7 (J), `todo.md` DEEP-13 |
| 29 | Wave 4 / J | Versioned Diagnostic Verification | Pulls fresh diagnostics tied to file modification ticks for post-edit self-healing (COMPAT-01) | File revision, server capability | Fresh diagnostic delta | Falls back to `unavailable` if server lacks versioned pull | `parallel-plan.md` §7 (J), `todo.md` COMPAT-01 |
| 30 | Wave 4 / K | Encapsulated Debugger Adapter | Exposes control, inspection, and lifecycle ports over Dape without modifying Dape itself | Debug launch config, project context | Debug session handle | Returns `unavailable` if Dape or DAP server is missing | `parallel-plan.md` §7 (K), `todo.md` ARCH-05 |
| 31 | Wave 4 / K | Debugger Active Unload & Advice Removal | Cleanly terminates debug sessions, sockets, and advice on package unload | Unload request | Cleaned environment | Removes all advice; kills orphan debug servers | `parallel-plan.md` §7 (K), `todo.md` ARCH-17 |
| 32 | Wave 4 / L | Atomic Persistence & Session Storage | Saves conversation sessions using temp files and atomic rename with 0600 permissions | Session record, destination directory | Persisted file path | Leaves original intact on write failure or disk full | `parallel-plan.md` §7 (L), `todo.md` DEEP-11 |
| 33 | Wave 4 / L | Multi-Writer Conflict Resolution | Detects external disk modifications and concurrent writers before committing file changes | Expected revision, disk state | Commit success or conflict error | Halts write and reports conflict on disk divergence | `parallel-plan.md` §7 (L), `todo.md` DEEP-10 |
| 34 | Wave 4 / L | Storage Data Lifecycle & Quota | Enforces storage quotas and retention policies on session archives and temp files | Storage directory, quota limits | Cleanup report | Deletes only owned artifacts; never follows symlinks | `parallel-plan.md` §7 (L), `todo.md` DEEP-15 |
| 35 | Wave 5 / M | Backend Execution-Owner Port | Abstracts agent loops behind an execution-owner SPI, supporting native and fake backends | Backend descriptor, session context | Backend lifecycle handle | Unsupported capabilities (e.g. resume) return `unavailable` | `parallel-plan.md` §8 (M), `todo.md` MOD-08 |
| 36 | Wave 5 / M | Fake Agent Backend Fixture | In-memory agent implementation providing deterministic tool calls, approvals, and events | Scripted test scenarios | Verified agent event sequence | Emulates disconnects, out-of-order events, and resets | `parallel-plan.md` §8 (M), `todo.md` DEEP-16 |
| 37 | Wave 5 / N | Programmatic Egress Policy | Enforces network and filesystem egress rules at programmatic gates based on connection snapshot | Request target, destination URL, payload | Permitted request or security denial | Blocks requests to unlisted hosts or cross-origin targets | `parallel-plan.md` §8 (N), `todo.md` DEEP-08/14 |
| 38 | Wave 5 / N | Structured Tool Argv Verification | Sanitizes tool arguments, enforces `--` delimiters, and validates canonical roots | Tool executable, argument list | Validated process invocation | Rejects option injections, shell expansions, and escape paths | `parallel-plan.md` §8 (N), `todo.md` ARCH-02 |
| 39 | Wave 5 / O | Test Docstring & Header Hygiene | Corrects checkdoc formatting, missing `;;; Code:` tags, and argument references in 18 legacy test files | 18 allowlisted test files | Clean checkdoc output | Never modifies test logic, assertions, or synthetic fixtures | `parallel-plan.md` §8 (O), `todo.md` TEST-01 |

---

## 5. Comprehensive Edge Cases Table

| # | Feature | Input / Condition | Observed / Documented Behavior |
|---|---|---|---|
| 1 | Single-Active-Run | Concurrent claim request on already running application instance | Second claim is immediately rejected with `:busy`; active run is unaffected. |
| 2 | Application Release | Release requested with stale or mismatched claim token | Release rejected with `:stale-claim`; active claim remains locked to legitimate owner. |
| 3 | Application Reset | Reset initiated on Session A while Session B has active request | Session A state, counters, and history are cleared; Session B request, process, and circuit state remain untouched. |
| 4 | Run Budget | Subtask or tool execution attempts to reset or overwrite parent budget | Subtask shares parent budget; local reset attempt is ignored; total consumption accumulates across subtasks. |
| 5 | Run Budget | Upstream provider returns response without `usage` token counts | Budget records tokens as `:unknown` (`tokens-unknown-p = t`); never coerces to 0 or assumes zero cost. |
| 6 | Edit Approval | Session configuration or active mode changes while edit approval is pending | Cached approval is invalidated; continuation fails; user must review and approve under new configuration. |
| 7 | Edit Approval | Target file modified externally while user reviews proposed diff | Re-validation upon user approval detects revision divergence; aborts write with `:conflict` without overwriting disk. |
| 8 | Edit Rollback | User modifies target file while a multi-file batch rollback is in progress | Rollback detects foreign writer / disk modification conflict; aborts rollback for that file and reports conflict without overwriting user edits. |
| 9 | Edit Service | Save-hook alters file content upon commit | Final save-hook transformation is reconciled into the transaction outcome; disk revision is updated. |
| 10 | Edit Service | Git index contains uncommitted user changes (`staged` files) | Isolated Git apply engine writes patch in temporary directory; user's `.git/index` is never touched. |
| 11 | Credential Discovery | Remote `auth-source` or GPG agent requires interactive password entry | Worker returns explicit `:auth-unavailable`; Emacs UI thread never blocks or prompts interactively. |
| 12 | Credential Discovery | Request cancelled or timeout reached while worker process is searching disk | Worker process is killed; timer cancelled; no leaked child process or late callback. |
| 13 | Tool Execution | Tool invoked via alias in readonly mode | Execution gate enforces readonly check regardless of alias; unauthorized write action is rejected with `:mode-disallowed`. |
| 14 | Tool Execution | Tool unregisters while long-running asynchronous execution is in flight | Gate drains running task or cancels it via async handle before unloading module code. |
| 15 | Transport (HTTP/SSE) | Inbound SSE stream contains 1 MB single line without newline delimiter | Stream bounds parser triggers limit violation; emits single terminal error; cleans up socket without memory overflow. |
| 16 | Transport (HTTP/SSE) | Server emits Unicode emoji split across two TCP packets | SSE parser buffers partial bytes and reconstructs valid UTF-8 sequence without character corruption. |
| 17 | Transport (Redirect) | Server returns 302 redirect from `api.example.com` to `evil.com` | Redirection logic strips `Authorization` and sensitive headers before dispatching request to new origin. |
| 18 | Process Lifecycle | Child process ignores `SIGTERM` on cancellation | Timeout fires; escalation sends `SIGKILL` to process group; prevents zombie processes. |
| 19 | Process Lifecycle | High concurrency ERT test execution causes stderr drain timing delay (RISK-01) | Deterministic event loop stepping waits for stderr EOF before closing process handle. |
| 20 | History Store | History contains orphan assistant tool-call without matching tool-result | Protocol wall repairs turn structure or sanitizes payload before dispatching to provider API. |
| 21 | Compaction | Compaction summary returns empty string or provider error | Loop handles failed compaction safely; does not corrupt existing history; terminates gracefully if context is full. |
| 22 | Chat View | Rapid SSE stream arrives while user is actively typing in draft prompt | Stream render queue batches updates and updates transcript without moving user point or losing keystrokes. |
| 23 | Chat View | User closes chat buffer while plan preparation is running asynchronously | View close cleanly unbinds listeners; cancels async preparation task; prevents error on missing buffer. |
| 24 | Log Privacy | Log writer encountered nested JSON structure containing API key in subfield | Common redaction layer recursively masks known secret keys before writing to log buffer. |
| 25 | Log Retention | Single log entry exceeds maximum buffer retention cap | Log buffer writes entry, immediately trims oldest content, and respects byte cap while preserving valid character boundaries. |
| 26 | LSP Coordinates | Symbol replacement spans wide Unicode characters (e.g. non-BMP emojis) | Widened buffer character conversion maps exact UTF-16 offset; replaces exact symbol without offset drift. |
| 27 | LSP Freshness | Eglot server provides only unversioned push diagnostics (COMPAT-01) | System does not treat unversioned push as verified clean; returns `:unavailable` unless pull capability exists. |
| 28 | Dape Debugger | User initiates Stop during asynchronous adapter compilation | Compilation process killed; socket closed; state machine transitions to stopped without hanging. |
| 29 | Dape Unload | Package unload triggered while debugging session is active | Active unload advice cancels sessions, tears down sockets, restores original functions, and returns timers to baseline. |
| 30 | Persistence Writer | Concurrent write attempt from another Emacs process on same session file | File lock / revision mismatch detects conflict; write is rejected; active session data is not overwritten. |
| 31 | Persistence Storage | Disk becomes full during session file write | Atomic publication fails in temp file; original session file remains completely intact and uncorrupted. |
| 32 | Fake Backend | External agent emits out-of-order execution events | Backend adapter buffers or rejects out-of-order events; maintains single execution owner invariant. |
| 33 | Egress Security | Malicious prompt in project file attempts injection to fetch external URL | Egress policy gate checks target against approved provider connection snapshot and denies outbound request. |
| 34 | Structured Tool Trust | Tool argument contains shell metacharacters or leading option flags (`-rf`) | Structured runner invokes executable directly with argv array and `--` separator; prevents option injection. |

---

## 6. Full Text of `architecture-contracts.md`

The authoritative `architecture-contracts.md` text has been drafted and saved to:
`/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/architecture-contracts.md`

The Coordinator / Worker can directly copy or commit this file to:
`/home/emrehan/.emacs.local/kargu/architecture-contracts.md`

---
*Report produced by Wave 0 Architecture Contracts Spec Miner.*
