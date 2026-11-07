# Kargu Architecture Contracts Inventory (Wave 0)

Authoritative specification establishing canonical boundaries, types, lifecycles, and verification invariants for the Kargu modular transformation (Waves 0–5).

---

## 1. Architectural Tenets & Cross-Cutting Invariants

1. **Single-Active-Run Invariant (ARCH-01, ARCH-12)**: Within an Emacs application instance, at most ONE agent execution loop (`kargu-run`) may be active at any given time. Runtime execution state is anchored strictly in an explicit `kargu-application` handle rather than global mutable variables (`kargu--loop-run`, `kargu--busy`, `kargu-application--context`).
2. **Pluggable & Detachable Adapters (ARCH-09)**: Feature modules (LSP, Dape, Bash, Git, Diff, Search, Webfetch, Chat UI, Plan Mode, External Backends) plug into core ports via dependency inversion. Core contracts never require concrete feature adapters. When an optional adapter is missing, core offline headless execution remains fully operational; missing adapters return typed `unavailable` states rather than crashing or claiming false success.
3. **Fail-Closed Security & Integrity (ARCH-02, ARCH-03, MOD-02)**: Missing permission or security adapters fail closed: unauthorized writes, shell executions, and egress requests are rejected. User approvals are single-use continuations bound to exact environment and policy revisions; preapproved or replay stores are strictly prohibited.
4. **Unified Accounting & Strict Bounds (DEEP-09, DEEP-12, MOD-04)**: All requests, retries, healing attempts, and compaction turns debit against a single run budget. Stream buffers, process output archives, and log buffers enforce hard byte/character caps on every write.
5. **No String Parsing for Control Decisions (ARCH-16)**: All status, error, and retry decisions must inspect canonical Result types (`kargu/contract/result.el`) with domain error symbols and effect plists. Parsing error strings to infer success or retryability is forbidden.

---

## 2. The 8 Core Boundary Contracts

```
+-----------------------------------------------------------------------------------+
|                              KARGU APPLICATION ROOT                               |
|                                                                                   |
|  +--------------------+   claims   +-------------------+  debits  +------------+  |
|  |     Chat View /    | ---------> | kargu-application | -------> | Run Budget |  |
|  | Headless Engine G  |            |   (Coordinator)   |          +------------+  |
|  +--------------------+            +-------------------+                          |
|             |                                |                                    |
|             | emits                          | spawns                             |
|             v                                v                                    |
|     +---------------+                +---------------+                            |
|     | Events Port   |                |  Async Scope  |                            |
|     +---------------+                +---------------+                            |
|             |                                | owns                               |
|      +------+------+                 +-------+-------+                            |
|      |             |                 |               |                            |
|      v             v                 v               v                            |
|  +--------+   +----------+     +------------+  +------------+                     |
|  | Result |   | Tool Gate|     | Transport  |  | Edit Svc B |                     |
|  | Contract   |    D     |     | Client E   |  +------------+                     |
|  +--------+   +----------+     +------------+        |                            |
|                    |                 |               v                            |
|                    |                 v        +-------------------+               |
|                    |          +-------------+ | kargu-file-current|               |
|                    |          | Connection  | |     revision      |               |
|                    |          | Snapshot C  | +-------------------+               |
|                    |          +-------------+                                     |
|                    v                                                              |
|            +---------------+                                                      |
|            | Feature Tools |                                                      |
|            +---------------+                                                      |
+-----------------------------------------------------------------------------------+
```

---

### Contract 1: Application Contract

#### 1.1 Purpose & Scope
The Application Contract establishes explicit application and coordinator lifecycle management. It eliminates reliance on scattered global runtime flags by managing run claims, session ownership, status transitions, and ordered resets per application instance.

#### 1.2 Roles
- **Producer**: Application Coordinator (`kargu/application/coordinator.el`, `kargu.el`).
- **Consumer**: Engine/Loop (`kargu/loop.el`), UI/Chat (`kargu/chat.el`), Plan Dispatcher (`kargu/plan/dispatch.el`), Reset service (`kargu/application/reset.el`).

#### 1.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`.
- **Optional**: Chat UI buffers, transient views (headless loop operates cleanly without UI).

#### 1.4 Input & Output Types
```elisp
(cl-defstruct (kargu-application (:constructor kargu-application--create))
  "Owned application coordinator for single-run and lifecycle state."
  (id (format "app-%s" (kargu-random-uuid)) :read-only t)
  (status :idle)
  (active-run nil)
  (active-claim-token nil)
  (active-request nil)
  (session-id nil)
  (generation 0))

(cl-defstruct (kargu-application-claim (:constructor kargu-application-claim--create))
  "Proof of exclusive execution claim on an application context."
  (token (format "claim-%s" (kargu-random-uuid)) :read-only t)
  (app-id nil :read-only t)
  (run-id nil :read-only t)
  (mode nil :read-only t)
  (created-at (float-time) :read-only t))
```
- `kargu-application-claim (app run-id mode &optional session-id)`:
  - **Inputs**: `app` (`kargu-application`), `run-id` (string), `mode` (symbol in `kargu-all-modes`), optional `session-id` (string).
  - **Outputs**: `(kargu-ok kargu-application-claim)` on success; `(kargu-err "Application is busy with an active run" :busy (:active-run ...))` on conflict.
- `kargu-application-release (app claim-token)`:
  - **Inputs**: `app` (`kargu-application`), `claim-token` (`kargu-application-claim` or string).
  - **Outputs**: `(kargu-ok t)` on success; `(kargu-err "Mismatched or stale claim token" :stale-claim)` if token does not match `active-claim-token`.

#### 1.5 Validation Owner
- `kargu/application/coordinator.el` asserts `kargu-application-p` at entry for all coordinator functions.

#### 1.6 State Machine & Lifecycle Events
- **States**: `:idle`, `:starting`, `:requesting`, `:streaming`, `:executing-tool`, `:waiting-approval`, `:compacting`, `:verifying`, `:done`, `:stopped`, `:error`, `:limit`, `:pause`.
- **Creation**: `kargu-application-create` creates an instance in `:idle` state with `generation = 0` and `active-run = nil`.
- **Claim Event**: `kargu-application-claim` verifies `(null active-run)` and `(eq status :idle)`. Upon success, sets `status = :starting`, assigns `active-claim-token`, binds `run-id`, and increments `generation`.
- **Release Event**: `kargu-application-release` validates matching claim token, cancels any live transport request, clears `active-run` and `active-claim-token`, and transitions `status` back to `:idle`.
- **Ordered Reset**: Reset follows strict sequence:
  1. Cancel active run (`kargu-loop-stop`).
  2. Flush session history (`kargu-history-reset`).
  3. Reset circuit breakers (`kargu-circuit-reset`).
  4. Reset coordinator state (`kargu-application-reset`).
  5. Notify passive view observers (`kargu-session-reset-hook`).
  Foreign sessions, unrelated processes, and other application contexts are left untouched.

#### 1.7 Ownership, Cleanup & Cancellation Invariants
- Claim must precede view notification: An agent run or UI command must successfully acquire the claim before updating buffer presentation or emitting view events.
- Releasing a claim only releases that exact claim; foreign or stale claim tokens are rejected.
- Composition passes `kargu-application` handle downward; submodules never perform global singleton lookups.
- Two isolated application contexts (`app-1` and `app-2`) never share or mutate each other's state.

---

### Contract 2: Async Scope Contract

#### 2.1 Purpose & Scope
The Async Scope Contract governs asynchronous task management, hierarchical parent-child cancellation trees, execution deadlines, and resource teardown barriers. It guarantees single-delivery completion and cleanly decouples cancellation requests from low-level process exits and terminal callbacks.

#### 2.2 Roles
- **Producer**: Async Task Manager (`kargu/async.el`).
- **Consumer**: Transport HTTP Client (`kargu/api/http.el`), Credential Worker (`kargu/config/worker.el`), Process Runner (`kargu/tools/process.el`), Edit Service (`kargu/edit.el`), Dape Adapter (`kargu/tools/dape/lifecycle.el`).

#### 2.3 Dependencies
- **Required**: `cl-lib`, `kargu/core/log.el`.
- **Optional**: None. Foundational boundary.

#### 2.4 Input & Output Types
```elisp
(cl-defstruct (kargu-async-task (:constructor kargu-async--make))
  "One task with a terminal state, resource cleanup stack, and single completion callback."
  (id (format "task-%s" (kargu-random-uuid)) :read-only t)
  (state :pending)
  (callback nil :read-only t)
  (timer nil)
  (owner nil :read-only t)
  (valid-p nil :read-only t)
  (cancel nil)
  (parent nil :read-only t)
  (buffer nil :read-only t)
  (deadline nil :read-only t))
```
- `kargu-async-start (callback &key timeout valid-p cancel owner parent buffer)`:
  - **Inputs**: `callback` (function of `(value error)`), keyword options `:timeout` (number of seconds), `:valid-p` (predicate checking environment validity), `:cancel` (thunk for resource release), `:owner` (run/app context), `:parent` (`kargu-async-task`), `:buffer` (origin buffer).
  - **Outputs**: `kargu-async-task` handle.
- `kargu-async-finish (task value &optional error)`:
  - **Inputs**: `task` (`kargu-async-task`), `value` (any), optional `error` (string or symbol).
  - **Outputs**: `nil`. Delivers `(value error)` to callback once.
- `kargu-async-cancel (task)`:
  - **Inputs**: `task` (`kargu-async-task`).
  - **Outputs**: `nil`. Transitions task and all child tasks to `:cancelled` and executes cleanups.
- `kargu-async-add-cleanup (task function)`:
  - **Inputs**: `task` (`kargu-async-task`), `function` (thunk).
  - **Outputs**: `nil`. Chains cleanup into task unwind stack.

#### 2.5 Validation Owner
- `kargu/async.el` enforces task structure and prevents duplicate terminal transitions.

#### 2.6 State Machine & Lifecycle Events
- **States**: `:pending`, `:done`, `:cancelled`.
- **Creation & Setup Barrier**: `kargu-async-start` fully constructs the task struct, registers it in `kargu-async--pending`, and establishes timer/parent links BEFORE any asynchronous operation or callback can execute. Early callbacks cannot bypass this barrier.
- **Hierarchical Cancellation**: When `kargu-async-cancel` is called on a parent task:
  1. Parent state transitions to `:cancelled`.
  2. All pending child tasks with `(eq task parent)` recursively transition to `:cancelled`.
  3. Watchdog timers are cancelled.
  4. Cleanup thunks are executed in LIFO order under `unwind-protect`.
- **Process Exit vs Terminal Delivery**: Low-level process or socket closure is distinct from terminal callback delivery. Stderr drain or buffer reading must complete before the terminal callback is invoked.
- **Single Delivery**: Exactly ONE invocation of `kargu-async-finish` reaches the callback. Duplicate calls are dropped silently.

#### 2.7 Ownership, Cleanup & Cancellation Invariants
- Cancellation is structured: cancelling a parent cancels all descendants; cancelling a child never cancels siblings or parents.
- An async task captures its origin buffer; if the buffer is killed, the task safely cancels without throwing unhandled buffer errors.
- Callback exceptions are trapped, logged, and attributed to the parent task without corrupting the global pending task list.

---

### Contract 3: Edit Service Contract

#### 3.1 Purpose & Scope
The Edit Service Contract provides a single-owned transaction boundary for all filesystem mutations. Block replacements, symbol edits, and Unified Diffs converge on a single transaction pipeline with verified source revisions, isolated review tables, safe Git apply execution, and rollback conflict resolution.

#### 3.2 Roles
- **Producer**: Edit Service (`kargu/edit.el`, `kargu/tools/diff.el`, `kargu/tools/diff/context.el`).
- **Consumer**: Tool Execution Gate (`kargu/tools/execution.el`), Native Loop (`kargu/loop.el`), Plan Dispatcher (`kargu/plan/dispatch.el`), LSP Symbol Editor (`kargu/tools/lsp/symbols.el`).

#### 3.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/result.el`, `kargu-file-current-revision` (bootstrap from `kargu/files.el`).
- **Optional**: Ediff review adapter, system `git` CLI (missing Git falls back to read-only or returns `:unavailable`).

#### 3.4 Input & Output Types
```elisp
(cl-defstruct (kargu-file-revision (:constructor kargu-file--make-revision))
  "Filesystem identity and content revision of one disk snapshot."
  (inode nil :read-only t)
  (device nil :read-only t)
  (bytes nil :read-only t)
  (mtime nil :read-only t))

(cl-defstruct (kargu-edit-service (:constructor kargu-edit-service--create))
  "Explicit edit-service context managing snapshot, review, change, and rollback tables."
  (service-id (format "edit-%s" (kargu-random-uuid)) :read-only t)
  (root nil :read-only t)
  (snapshots (make-hash-table :test #'equal))
  (changes (make-hash-table :test #'equal))
  (reviews (make-hash-table :test #'equal))
  (active-plans (make-hash-table :test #'equal))
  (policy-revision 0))

(cl-defstruct (kargu-edit-plan (:constructor kargu-edit-plan--create))
  "Immutable captured transaction plan for proposed file modifications."
  (plan-id (format "plan-%s" (kargu-random-uuid)) :read-only t)
  (path nil :read-only t)
  (kind nil :read-only t) ; :block, :symbol, :unified-diff, :write
  (proposed-content nil :read-only t)
  (expected-revision nil :read-only t) ; kargu-file-revision
  (policy-revision 0 :read-only t)
  (session-id nil :read-only t)
  (created-at (float-time) :read-only t))

(cl-defstruct (kargu-edit-outcome (:constructor kargu-edit-outcome--create))
  "Unified transaction outcome for file editing operations."
  (plan-id nil :read-only t)
  (path nil :read-only t)
  (status nil :read-only t) ; :applied, :staged, :conflict, :partial, :unavailable
  (post-revision nil :read-only t) ; kargu-file-revision after save-hooks
  (hunks-applied 0 :read-only t)
  (hunks-total 0 :read-only t)
  (message nil :read-only t))
```
- `kargu-file-current-revision (path)`:
  - **Inputs**: `path` (valid file path string).
  - **Outputs**: `kargu-file-revision` struct.
- `kargu-edit-submit-plan (service plan &key callback)`:
  - **Inputs**: `service` (`kargu-edit-service`), `plan` (`kargu-edit-plan`), optional `callback`.
  - **Outputs**: `(kargu-ok kargu-edit-outcome)` or `(kargu-err message code data)`.

#### 3.5 Validation Owner
- `kargu/tools/diff/context.el` and `kargu/edit.el`. Ingress validates `path`, `kargu-contract-filepath-p`, and non-empty content.

#### 3.6 State Machine & Lifecycle Events
- **States**: `:captured`, `:pending-approval`, `:applying`, `:committed`, `:aborted`, `:conflict`.
- **Plan Capture**: Captures current disk revision via `kargu-file-current-revision`, active session ID, and policy revision.
- **Approval Re-Validation (ARCH-03)**: If user confirmation is required, the plan waits in `:pending-approval`. When the user approves, the service re-reads the disk/buffer revision. If the revision changed during the wait, the approval is invalidated, the transaction aborts with `:conflict`, and the user is prompted with the updated document.
- **Execution & Save-Hook Reconciliation**: Changes are applied (via block replacement, symbol AST edit, or isolated `git apply`). After save-hooks run, the post-write revision is captured and verified.
- **Rollback on Abort**: If a multi-file batch is stopped or fails on file N, previously applied files in the batch are rolled back using saved snapshots. If a concurrent writer touched a file during the batch, rollback stops and reports a conflict without clobbering external changes.
- **Service Close**: Releases only its own review buffers, scratch files, and temp diffs.

#### 3.7 Ownership, Cleanup & Cancellation Invariants
- ARCH-04: Block, symbol, and Unified Diff pipelines share identical transaction semantics and produce `kargu-edit-outcome` records.
- Working tree protection: Never invokes `git apply --cached` or mutates `.git/index`. Git apply runs strictly in isolated temp files.
- Two edit services operating on the same project or different projects maintain completely disjoint change tables.

---

### Contract 4: Connection Snapshot Contract

#### 4.1 Purpose & Scope
The Connection Snapshot Contract guarantees that all network transport requests, catalog discoveries, and model completions execute against an immutable, verified connection snapshot. Secrets are resolved asynchronously in the background and strictly isolated from command-line arguments, log records, and session history (CONFIG-01, DEEP-14).

#### 4.2 Roles
- **Producer**: Config & Connection Resolver (`kargu/config/connection.el`, `kargu/config/worker.el`).
- **Consumer**: Transport HTTP Client (`kargu/api/http.el`, `kargu/api/client.el`), Circuit Breaker (`kargu/api/circuit.el`), Catalog Service (`kargu/providers/catalog.el`), Egress Gate (`kargu/permission/policy.el`).

#### 4.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`.
- **Optional**: `auth-source` (accessed strictly via nonblocking background worker; synchronous UI invocation is prohibited).

#### 4.4 Input & Output Types
```elisp
(cl-defstruct (kargu-connection-snapshot (:constructor kargu-connection-snapshot--create))
  "Immutable verified snapshot of provider connection target and credentials."
  (id (format "conn-%s" (kargu-random-uuid)) :read-only t)
  (provider nil :read-only t) ; string (e.g. "openai", "anthropic")
  (model nil :read-only t) ; string
  (endpoint nil :read-only t) ; valid http/https URL string
  (wire-format :openai :read-only t) ; symbol: :openai, :anthropic, :ollama
  (capabilities nil :read-only t) ; plist (:tools t :stream t :reasoning nil)
  (config-revision 0 :read-only t) ; integer
  (credential-scope nil :read-only t) ; opaque handle holding resolved secret
  (created-at (float-time) :read-only t))
```
- `kargu-connection-resolve-async (provider model &key callback timeout)`:
  - **Inputs**: `provider` (string), `model` (string), `callback` (function of `(result)`), optional `timeout`.
  - **Outputs**: `kargu-async-task` handle. Callback receives `(kargu-ok kargu-connection-snapshot)` or `(kargu-err message :auth-unavailable data)`.
- `kargu-connection-redacted-summary (snapshot)`:
  - **Inputs**: `snapshot` (`kargu-connection-snapshot`).
  - **Outputs**: Safe plist suitable for logging without credentials: `(:provider ... :model ... :endpoint ... :config-revision ...)`.

#### 4.5 Validation Owner
- `kargu/config/connection.el`. Validates URL syntax via `kargu-contract-url-p`, verifies provider configuration against schema, and asserts required wire capabilities.

#### 4.6 State Machine & Lifecycle Events
- **States**: `:resolving`, `:ready`, `:invalidated`, `:cancelled`.
- **Async Secret Discovery (CONFIG-01)**: When resolving credentials:
  1. Memory/direct configuration keys are resolved immediately.
  2. Disk or auth-source lookups spawn a cancellable worker process (`kargu/config/worker.el`). The Emacs UI thread never blocks.
  3. If an interactive passphrase or GPG prompt is required and noninteractive mode is active, the worker immediately returns `(kargu-err "Interactive authentication unavailable in background discovery" :auth-unavailable)`.
- **Immutable Snapshot**: Once created, the snapshot slots are read-only.
- **Retry Preservation**: Transport retries for a logical request reuse the identical connection snapshot. A mid-flight configuration change on disk does not mutate the active snapshot.
- **Teardown & Wiping**: On session reset or application shutdown, credential scope references are zeroed and unreferenced.

#### 4.7 Ownership, Cleanup & Cancellation Invariants
- Zero secret leakage (DEEP-14): Credential tokens NEVER appear in process `argv`, log files, transcript buffers, debug strings, or saved session files.
- Origin isolation: If an HTTP redirect points to a different origin (host/port/protocol), the transport strips all credential headers before following the redirect.
- Cancelling discovery cleanly terminates any spawned background resolution worker without orphan processes.

---

### Contract 5: Tool Registry & Execution Gate Contract

#### 5.1 Purpose & Scope
The Tool Registry & Execution Gate Contract provides a single, unified gate for tool registration, parameter schema validation, mode checks, single-use permission approvals, output budgeting, and asynchronous execution. It decouples immutable tool definitions from mutable execution instances (MOD-02, ARCH-02, ARCH-03, ARCH-09).

#### 5.2 Roles
- **Producer**: Composition Root / Tool Registry (`kargu/tools/registry.el`, `kargu/tools/execution.el`).
- **Consumer**: Headless Engine (`kargu/loop/tools.el`), Direct API caller (`kargu/api/tools.el`), Interactive Chat UI.

#### 5.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/async.el`, `kargu/permission/guards.el`.
- **Optional**: Feature adapters (LSP, Dape, Bash, Git, Diff, Search, Webfetch).

#### 5.4 Input & Output Types
```elisp
(cl-defstruct (kargu-tool-definition (:constructor kargu-tool-registry--definition-create))
  "Validated tool definition; schema and policy remain borrowed read-only records."
  (name nil :read-only t)
  (description nil :read-only t)
  (parameters nil :read-only t) ; JSON schema alist
  (executor nil :read-only t) ; (lambda (args on-done) ...)
  (policy nil :read-only t)) ; plist (:modes (...) :available-p fn)

(cl-defstruct (kargu-tool-execution-context (:constructor kargu-tool-execution-context--create))
  "Context passed to tool execution gate."
  (context-id (format "exec-%s" (kargu-random-uuid)) :read-only t)
  (app nil :read-only t) ; kargu-application
  (run-id nil :read-only t)
  (session-id nil :read-only t)
  (root default-directory :read-only t)
  (mode 'agent :read-only t)
  (budget-scope nil :read-only t)
  (policy-revision 0 :read-only t))

(cl-defstruct (kargu-tool-approval (:constructor kargu-tool-approval--create))
  "Single-use captured approval token for guarded execution."
  (token-id (format "appr-%s" (kargu-random-uuid)) :read-only t)
  (tool-name nil :read-only t)
  (args-hash nil :read-only t)
  (root nil :read-only t)
  (policy-revision 0 :read-only t)
  (claimed-p nil))
```
- `kargu-tool-gate-execute (registry context name raw-args &key callback)`:
  - **Inputs**: `registry` (`kargu-tool-registry`), `context` (`kargu-tool-execution-context`), `name` (string), `raw-args` (JSON string or alist), optional `callback`.
  - **Outputs**: `kargu-async-task` handle. Callback receives formatted truncated result string or `(kargu-err message code data)`.

#### 5.5 Validation Owner
- Tool Execution Gate (`kargu/tools/execution.el`). Validates:
  1. Canonical name resolution (flattening aliases).
  2. Tool presence in registry.
  3. Mode gating (e.g. mutating tools prohibited in `:ask` or `:plan` mode).
  4. Parameter schema validation (`kargu-contract-tool-schema-p`).
  5. Policy availability (`:available-p`).
  6. Captured single-use approval verification.
  7. Output truncation and archive quota management.

#### 5.6 State Machine & Lifecycle Events
- **States**: `:validating`, `:awaiting-approval`, `:executing`, `:truncating`, `:completed`, `:draining`.
- **Single-Use Captured Approval (ARCH-03)**:
  - If a command requires user confirmation, an approval continuation is captured.
  - When approved, the gate verifies `(null (kargu-tool-approval-claimed-p approval))`.
  - The token is immediately marked `claimed-p = t`.
  - Replay attempts are rejected with `:approval-stale`.
- **Output Bounding & Quota**:
  - Tool outputs exceeding `kargu-tool-output-limit` are truncated.
  - Omitted text is preserved in project-owned buffer `*kargu-output-N*` up to `kargu-tool-output-archive-max-chars`.
  - Oldest untouched archive buffers are evicted to respect `kargu-tool-output-archive-max-buffers`.
- **Active Unload / Drain (ARCH-09)**:
  - Unregistering or disabling a tool marks the definition in draining state.
  - Running async tasks are allowed to complete or cancelled via their async handles before code is detached.

#### 5.7 Ownership, Cleanup & Cancellation Invariants
- Single gate for direct and alias invocations: compatibility aliases pass through the exact same permission and validation checks.
- Mutable execution state belongs to `kargu-tool-execution-context`, never stored in `kargu-tool-definition`.
- Fail-closed: If permission checks or security adapters are missing, execution is denied.

---

### Contract 6: Budget Accounting Contract

#### 6.1 Purpose & Scope
The Budget Accounting Contract establishes a single, unified debit gate for all operations in an agent run. Standard requests, retries, self-healing turns, and context compactions all debit from the shared run budget. Unknown token metrics are tracked explicitly and never coerced to zero (DEEP-09).

#### 6.2 Roles
- **Producer**: Application Run Budget Manager (`kargu/application/budget.el`).
- **Consumer**: Headless Loop (`kargu/loop.el`), Transport Client (`kargu/api/http.el`, `kargu/api/retry.el`), Context Compactor (`kargu/loop/compact.el`), Diagnostics Healer (`kargu/loop/heal.el`).

#### 6.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/result.el`.
- **Optional**: None.

#### 6.4 Input & Output Types
```elisp
(cl-defstruct (kargu-run-budget (:constructor kargu-run-budget--create))
  "Unified accounting record for requests, deadlines, and tokens per run."
  (run-id nil :read-only t)
  (max-requests 30 :read-only t)
  (requests-spent 0)
  (deadline nil :read-only t) ; float-time or nil
  (max-tokens nil :read-only t)
  (tokens-spent 0)
  (tokens-unknown-p nil)
  (status :ok)) ; :ok, :exhausted-requests, :exhausted-deadline, :exhausted-tokens
```
- `kargu-budget-create (&key run-id max-requests timeout max-tokens)`:
  - **Inputs**: `run-id` (string), optional `max-requests` (integer), `:timeout` (seconds), `:max-tokens` (integer).
  - **Outputs**: `kargu-run-budget` struct.
- `kargu-budget-debit (budget debit-type &key requests tokens)`:
  - **Inputs**: `budget` (`kargu-run-budget`), `debit-type` (symbol: `:normal-request`, `:retry-attempt`, `:compaction-turn`, `:healing-turn`, `:continuation`), optional `requests` (default 1), optional `tokens`.
  - **Outputs**: `(kargu-ok budget)` if permitted; `(kargu-err message :budget-exhausted (:reason status))` if limit reached.
- `kargu-budget-record-tokens (budget prompt-tokens completion-tokens)`:
  - **Inputs**: `budget` (`kargu-run-budget`), `prompt-tokens` (integer or nil), `completion-tokens` (integer or nil).
  - **Outputs**: `budget`. If tokens are nil, sets `tokens-unknown-p = t`.

#### 6.5 Validation Owner
- `kargu/application/budget.el`. Enforces positive integers on debits and validates monotonic accumulation.

#### 6.6 State Machine & Lifecycle Events
- **States**: `:ok`, `:exhausted-requests`, `:exhausted-deadline`, `:exhausted-tokens`.
- **Creation**: Instantiated at run claim time; bound to `kargu-application`.
- **Debit Gate**: Before dispatching any HTTP call or turn, the caller MUST call `kargu-budget-debit`. If `requests-spent + requests > max-requests` or `(float-time) > deadline`, the debit is denied and the budget status transitions to the respective exhausted state.
- **Usage Attribution**: When model response usage arrives, `kargu-budget-record-tokens` updates token totals. If usage is missing from wire response, `tokens-unknown-p` is set to `t`; usage is NEVER recorded as 0.
- **Single Compaction Invariant**: At most one compaction debit is granted per run by default unless an explicit multi-stage compaction policy is configured.
- **Subtask Immunity**: Nested tools or subagents cannot reset or replace the parent run budget.

#### 6.7 Ownership, Cleanup & Cancellation Invariants
- Unified gate (DEEP-09): All turn types (initial, retry, compact, heal) draw from the same request and token counter.
- Unknown usage integrity: Upstream missing token data is acknowledged as unknown; no artificial token counts are fabricated.
- Closing or cancelling a run seals the budget against further debits.

---

### Contract 7: Events Contract

#### 7.1 Purpose & Scope
The Events Contract defines the protocol for event communication across the system. It enforces a strict boundary between passive observable notifications (which cannot modify state or block execution) and control requests (which demand an explicit user or system decision) (MOD-01, ARCH-06, ARCH-07).

#### 7.2 Roles
- **Producer**: Headless Loop Engine (`kargu/loop.el`), Transport SSE Parser (`kargu/api/stream.el`), Process Runner (`kargu/tools/process.el`).
- **Consumer**: Chat UI View (`kargu/chat/stream.el`), Passive Observers (`kargu/core/observers.el`), Log Redactor (`kargu/core/log.el`).

#### 7.3 Dependencies
- **Required**: `kargu/contract/assert.el`, `kargu/contract/types.el`.
- **Optional**: Chat UI, transcript buffers.

#### 7.4 Input & Output Types
```elisp
(cl-defstruct (kargu-event-id (:constructor kargu-event-id--create))
  "Minimal traceable identifier for event correlation."
  (run-id nil :read-only t)
  (session-id nil :read-only t)
  (request-id nil :read-only t)
  (sequence-no 0 :read-only t)
  (timestamp (float-time) :read-only t))

(cl-defstruct (kargu-passive-event (:constructor kargu-passive-event--create))
  "Immutable notification event for observers and views."
  (id nil :read-only t) ; kargu-event-id
  (type nil :read-only t) ; :stream-chunk, :turn-start, :tool-start, :tool-finish, :run-finish
  (payload nil :read-only t))

(cl-defstruct (kargu-control-request (:constructor kargu-control-request--create))
  "Asynchronous control request requiring human or policy decision."
  (id (format "ctrl-%s" (kargu-random-uuid)) :read-only t)
  (kind nil :read-only t) ; :confirmation, :plan-approval
  (prompt nil :read-only t)
  (default-action :reject :read-only t) ; :reject, :stop, :cancel
  (on-decision nil :read-only t) ; (lambda (decision) ...)
  (timeout nil :read-only t))
```
- `kargu-event-emit (engine event)`:
  - **Inputs**: `engine` context, `event` (`kargu-passive-event`).
  - **Outputs**: `nil`. Dispatches to registered observers under error trap.
- `kargu-control-request-submit (request)`:
  - **Inputs**: `request` (`kargu-control-request`).
  - **Outputs**: `nil`. Dispatches to confirmation adapter or invokes `default-action` immediately if headless.

#### 7.5 Validation Owner
- Loop Engine / Event Dispatcher (`kargu/loop/machine.el`). Asserts event type and validates monotonic sequence numbering.

#### 7.6 State Machine & Lifecycle Events
- **Monotonic Sequence**: Events emitted within a run increment `sequence-no` monotonically.
- **Observer Isolation**: Observers are passive listeners. Observer callbacks are invoked within `condition-case-unless-debug`. An error in an observer is logged but NEVER terminates the agent loop or corrupts loop state.
- **Single Terminal Event**: Every run emits exactly ONE terminal event (`:run-finish`) containing terminal status (`:done`, `:stopped`, `:error`, `:limit`). Late chunks after terminal event are discarded.
- **Control Request Fallback**: When running headlessly without a UI confirmation adapter, control requests immediately evaluate `(funcall on-decision default-action)` where default action is safely `:reject` or `:stop`.

#### 7.7 Ownership, Cleanup & Cancellation Invariants
- Passive events are immutable; observers must not mutate event payload records.
- Control requests cannot default to approval; default action must be `:reject`, `:stop`, or `:cancel`.
- Stream chunks in UI view use a bounded, coalesced rendering queue; delayed view updates cannot block engine processing.

---

### Contract 8: Results Contract

#### 8.1 Purpose & Scope
The Results Contract provides the single, canonical Railway-Oriented Programming Result algebraic data type for Kargu. It eliminates string parsing for status, error handling, and retry decisions by supplying typed domain error codes and explicit side-effect tracking (ARCH-16).

#### 8.2 Roles
- **Producer**: All core modules and adapters (`kargu/contract/result.el`, `kargu/api/http.el`, `kargu/edit.el`, `kargu/permission.el`, `kargu/tools/execution.el`).
- **Consumer**: Error handlers, retry dispatchers, self-healing loop, ERT test assertions.

#### 8.3 Dependencies
- **Required**: `kargu/contract/result.el`. Foundational module with zero internal dependencies.
- **Optional**: None.

#### 8.4 Input & Output Types
```elisp
(cl-defstruct (kargu-result-ok (:constructor kargu-ok (value)))
  "Successful result carrying VALUE."
  value)

(cl-defstruct (kargu-result-err (:constructor kargu-err (message &optional code data)))
  "Failed result carrying MESSAGE, optional numeric/symbol CODE, and DATA."
  message
  code
  data)
```
- `kargu-ok (value)` -> constructs `kargu-result-ok`.
- `kargu-err (message &optional code data)` -> constructs `kargu-result-err`.
- `kargu-ok-p (result)` -> `t` if `kargu-result-ok`, else `nil`.
- `kargu-err-p (result)` -> `t` if `kargu-result-err`, else `nil`.
- `kargu-result-value (result)` -> extracts `value` from `kargu-result-ok`, else `nil`.

#### 8.5 Canonical Domain Error Codes
```elisp
;; Application / Lifecycle
:busy                     ; Application already has an active run (ARCH-01)
:stale-claim              ; Presented claim token does not match active claim
:already-active           ; Run is already active
:invalid-transition       ; FSM state transition disallowed
:stopped                  ; Operation stopped by user / observer

;; Network / Transport
:http-status-429          ; Rate limited / Too Many Requests
:http-status-500          ; Internal Server Error
:http-status-502          ; Bad Gateway
:http-status-503          ; Service Unavailable
:http-status-504          ; Gateway Timeout
:http-status-529          ; Overloaded
:timeout                  ; Operation deadline exceeded
:connection-failed        ; TCP connection failed / DNS error
:tls-error                ; TLS handshake failure or invalid certificate
:stream-error             ; SSE framing or UTF-8 decoding error

;; Tool / Execution Gate
:no-such-tool             ; Tool name not found in registry
:tool-unavailable         ; Tool registered but currently disabled by policy
:mode-disallowed          ; Tool disallowed in active interaction mode
:invalid-arguments        ; Arguments failed JSON schema validation
:permission-denied        ; Operation denied by path/command guards
:approval-stale           ; Single-use approval token already claimed or invalidated
:budget-exhausted         ; Run request/token/deadline budget depleted
:execution-failed         ; Tool executor signalled error

;; Edit / Writer
:revision-conflict        ; Target file modified on disk; revision mismatch
:file-not-found           ; Target file does not exist within permitted root
:binary-file              ; File appears to be binary; text edit disallowed
:save-hook-failed         ; Emacs save-hook signalling error
:rollback-conflict        ; Conflict detected while attempting batch rollback
:disk-full                ; Write failed due to exhausted disk space

;; Adapter / Capability
:unavailable              ; Optional feature adapter not installed or active
:unsupported-capability   ; Model or server lacks requested capability
:unversioned-push         ; Diagnostics provider only pushes unversioned ticks
```

#### 8.6 Effect Status Descriptor
When returning `kargu-result-err`, the `data` slot may contain an effect plist:
`(:side-effect :none | :partial | :committed | :unknown)`
- `:none`: Safe to retry immediately; no state or disk was altered.
- `:partial`: Partial changes were made; automatic blind retry is forbidden without rollback or inspection.
- `:committed`: Change completed before error occurred (e.g. post-save hook failed).
- `:unknown`: Transport dropped connection before receiving response; blind retry is prohibited.

#### 8.7 Invariants
- ARCH-16: `kargu/contract/result.el` is the sole Result framework in the codebase. Introducing a second Result or Either library is strictly prohibited.
- No string parsing: Retry dispatchers and loop healers MUST check `code` and `data` properties, NEVER regex match against `message`.
- Monadic railway safety: Unhandled exceptions are converted to `kargu-result-err` at boundary entry points.

---

## 3. Wave 0 Acceptance Gates & Verification Fixtures

Wave 0 establishes the baseline boundaries that unlock subsequent waves. The following three acceptance gates must be verified before Wave 1 commences:

### Gate 1: Dual-Application Isolation Fixture
- **Requirement**: Two distinct `kargu-application` coordinator instances (`app-1` and `app-2`) operate independently within the same Emacs process.
- **Verification Criteria**:
  1. Claiming `app-1` sets its status to `:starting` with a valid claim token.
  2. `app-2` remains in `:idle` status with `(null (kargu-application-current-run app-2))`.
  3. Resetting `app-1` clears its active claim without disturbing `app-2`.
  4. Global variables do not leak state between `app-1` and `app-2`.

### Gate 2: Single-Active-Run Rejection
- **Requirement**: When `kargu-application-claim` has been acquired on context `app`, a second concurrent claim on `app` is immediately rejected.
- **Verification Criteria**:
  1. First claim returns `(kargu-ok claim-1)`.
  2. Second claim with different `run-id` returns `(kargu-err "Application is busy with an active run" :busy ...)`.
  3. First claim continues running undisturbed.
  4. Only `claim-1` can release the application context.

### Gate 3: Pluggable Independent Contract Loading
- **Requirement**: Public contract definitions under `kargu/contract/*.el` load cleanly without runtime or optional feature modules.
- **Verification Criteria**:
  1. Batch evaluation of `(require 'kargu/contract)` succeeds in clean `emacs -Q`.
  2. Forbidden runtime features (`kargu/core`, `kargu/state`, `kargu/chat`, `kargu/loop`, `kargu/tools/lsp`, `kargu/tools/dape`, `kargu/tools/diff`) are NOT loaded (`featurep` returns `nil`).
  3. State stores, tool registries, and session contexts are NOT initialized upon contract loading.

### Gate 4: Public File Revision Reader Bootstrap
- **Requirement**: `kargu-file-current-revision` is exposed in `kargu/files.el` as a public API returning a verified `kargu-file-revision` struct before Wave 1.
- **Verification Criteria**:
  1. `(kargu-file-current-revision path)` returns `kargu-file-revision` with valid `inode`, `device`, `bytes`, and `mtime`.
  2. Package B (Wave 1) consumes `kargu-file-current-revision` directly, eliminating cross-module private calls (`kargu-file--file-revision`) without introducing an ad-hoc disk reader.

---

## 4. Contract-to-Package Mapping Matrix

| Contract Boundary | Primary Owner (Wave 0) | Consuming Package (Wave 1) | Consuming Package (Wave 2) | Consuming Package (Wave 3) | Consuming Package (Wave 4) | Consuming Package (Wave 5) |
|---|---|---|---|---|---|---|
| **1. Application** | Coordinator | Package A (`kargu/application/coordinator.el`) | Package D (Gate), Package E (Transport) | Package G (Loop), Package H (View/Plan) | Package K (Dape), Package L (Writer) | Package M (Backend Port) |
| **2. Async Scope** | Coordinator | Package A (`kargu/async.el`) | Package E (HTTP), Package F (Process) | Package G (Loop), Package H (View) | Package J (LSP), Package K (Dape) | Package M (Backend) |
| **3. Edit** | Coordinator / Bootstrap | Package B (`kargu/edit.el`, `kargu/tools/diff.el`) | Package D (Tool Gate) | Package G (Loop Self-Heal) | Package J (LSP symbols), Package L (Writer) | Package N (Egress Policy) |
| **4. Connection** | Coordinator | Package C (`kargu/config/connection.el`) | Package E (`kargu/api/http.el`, Circuit) | Package H (Catalog Service) | Package L (Persistence) | Package N (Egress Boundary) |
| **5. Tool Gate** | Coordinator | Package B (Diff tools) | Package D (`kargu/tools/execution.el`) | Package G (Loop Tools) | Package J (LSP), Package K (Dape) | Package N (Argv Trust) |
| **6. Budget** | Coordinator | Package A (`kargu/application/budget.el`) | Package E (Debit per attempt) | Package G (Shared Loop Debit) | Package L (Quota) | Package M (Fake Agent) |
| **7. Events** | Coordinator | Package A (Reset hooks) | Package E (SSE chunks), Package F (Process) | Package G (Loop Machine), Package H (View Queue) | Package K (Dape Events) | Package M (Backend Port) |
| **8. Results** | Coordinator (`contract/result.el`) | Package A, B, C | Package D, E, F | Package G, H, I | Package J, K, L | Package M, N, O |

---
*Authoritative document approved for Wave 0 integration baseline.*
