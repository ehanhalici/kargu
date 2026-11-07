# Architectural Investigation & Design Blueprint: Wave 3 Package H
**Owned View, Selection, Catalog & Plan Services**

- **Author**: `explorer_wave3_H`
- **Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H`
- **Target Role**: `worker_wave3_H`
- **Milestone**: Wave 3 Package H
- **Date**: 2026-10-22

---

## 1. Executive Summary

Package H transitions view presentation, selection management, provider/model catalog discovery, and plan review services from scattered global state and implicit buffer routing to explicit, owned ports and contracts.

### Core Architectural Guarantees Established:
1. **Catalog & Metadata Service**:
   - Encapsulates generation counters, live model ID caches, session tool refusals, and prefetch states in an explicit service struct (`kargu-catalog-service`).
   - Eliminates global mutable hash tables (`kargu--catalog-generations`, `kargu--live-models-cache`, `kargu--tools-refused`, `kargu--models-prefetched`) by anchoring them to an owned service context.
   - Binds model capability revisions (`:tools`, `:stream`, `:reasoning`, `:context-window`, `:max-output`, `:catalog-revision`) to Package C's immutable `kargu-connection-snapshot`. Active runs and transport consumers read frozen capabilities and never re-query mutable metadata mid-run.
   - Preserves strict semantic distinctions between `off` (reasoning disabled), `none` (no API efforts), `inherit` (fallback to configuration), and `successful-empty` (API returned 200 with 0 models, distinct from network failure).

2. **Owned View & Selection**:
   - Decouples selection and view state from global buffer lookups (`kargu-chat-find-buffer`, `*kargu-chat*`); buffer views observe Package A application coordinator (`kargu-application`) and Package G engine events.
   - Eliminates secondary state stores: transcript, prompt, footer, and header are pure projections of `kargu-session` and `kargu-application`.
   - Enforces a bounded, coalesced UI render queue for streaming text deltas (`kargu-chat--render-queue`), preventing Emacs UI thread starvation during event storms while keeping `[Stop]` / `C-c C-k` accessible at all times.
   - Preserves draft text, point position, buffer narrowing (`narrow-to-region`), and IME/Unicode composition during background streaming.

3. **Scoped Confirmations**:
   - Scopes pending confirmations by view/job handles rather than a single shared global pending list (`kargu-confirm--pending`).
   - Buffer close (`kill-buffer-hook`) cancels only the closing view's confirmations; foreign views' prompts remain intact.
   - In headless execution, control requests immediately deliver `default-action` (`:reject`, `:stop`, `:cancel`) without enqueuing or blocking.

4. **Plan Dispatcher & Resource Teardown**:
   - Plan dispatcher calls application coordinator port (`kargu-application-claim`) rather than private internal loop functions.
   - Preserves claim token, approved revision, draft state, and mode preparation (`agent`), with safe mode rollback on refusal.
   - Cleanly tears down subscriptions, watchers, and model picker resources on buffer close.
   - Preserves existing markers and UX: split-buffer/header-line layout experiments are explicitly excluded from this scope.

5. **Formal Verification & Test Suite**:
   - Exhaustive TLC model checks pass for `proof/KarguSelection.tla` (`--selection`) and `proof/KarguPlan.tla` (`--plan`).
   - Designed new test suite `tests/test-view-lifetime.el` covering dual project isolation, focus safety, stream preservation, responsive Stop, confirmation close, model service isolation, and resource teardown.

---

## 2. Existing Codebase Analysis & Problem Inventory

### 2.1 Catalog & Metadata Storage Analysis
- **Observed Paths**: `kargu/api/catalog.el`, `kargu/models/store.el`, `kargu/providers/catalog.el`, `kargu/config/connection.el`.
- **Findings**:
  1. `kargu/api/catalog.el` declares top-level mutable tables:
     - `kargu--catalog-generations`: line 35
     - `kargu--live-models-cache`: line 43
     - `kargu--tools-refused`: line 342
     - `kargu--models-prefetched`: line 586
     These tables are mutable singletons violate ARCH-12. If two application instances or isolated tests run in parallel, mutations in one collide with the other.
  2. In `kargu/config/connection.el` (`kargu-connection-resolve-async`), capabilities are derived via:
     `(kargu-connection--default-capabilities pname-lower)`
     which only inspects provider wire format and effort specs. It omits model-specific metadata (`supports_tools`, `supports_reasoning`, `context_window`) and does not record a metadata revision counter.
  3. Consequently, if a model metadata override occurs mid-flight or if an API response arrives while an agent run is executing, consumers querying `kargu-model-supports-tools-p` could see capabilities change during an active run, violating Contract 4 (Snapshot Immutability).

### 2.2 Chat View & Streaming Analysis
- **Observed Paths**: `kargu/chat.el`, `kargu/chat/select.el`, `kargu/chat/stream.el`, `kargu/chat/transcript.el`, `kargu/chat/prompt.el`.
- **Findings**:
  1. `kargu-chat--on-delta` in `kargu/chat/stream.el` (line 76) executes synchronous insertion directly on the UI thread for every incoming SSE chunk:
     `kargu-chat-insert` -> `kargu-chat-insert-into` -> `insert` -> `kargu-chat--apply-window-follow-states`.
     Under high chunk volume (e.g. 50-100 chunks/sec from fast local models or cloud providers), this triggers heavy garbage collection, recalculates window points on every token, and starves Emacs event processing, making `kargu-chat-stop` (`C-c C-k` / `[Stop]`) unresponsive.
  2. `kargu-chat-output-buffer` in `transcript.el` (lines 55-62) falls back to `(kargu-chat-find-buffer)`. If multiple chat buffers exist across projects, a delayed stream event or callback can incorrectly target an unrelated project's buffer.
  3. In `kargu/chat/select.el`, `kargu-api-select--chat-buffer` (line 217) similarly falls back to `(kargu-chat-find-buffer)`. While `kargu-api-select--focus-unchanged-p` protects window point and draft modification tick, the selector logic relies on dynamic `current-buffer` rather than an explicit view handle.

### 2.3 Confirmation UI Analysis
- **Observed Paths**: `kargu/ui/confirm.el`.
- **Findings**:
  1. Line 41: `(defvar kargu-confirm--pending nil)` is a single global list of all pending confirmation requests across the entire Emacs session.
  2. `kargu-confirm-dismiss-all` (line 231) dismisses prompts across all projects and views indiscriminately.
  3. `kargu-confirm--resolve-chat-buffer` (lines 93-98) defaults to `(get-buffer "*kargu-chat*")`, which is a global singleton name.

### 2.4 Plan Review & Dispatch Analysis
- **Observed Paths**: `kargu/plan.el`, `kargu/plan/context.el`, `kargu/plan/store.el`, `kargu/plan/dispatch.el`, `kargu/plan/buffer.el`, `kargu/chat/plan.el`.
- **Findings**:
  1. In `kargu/chat/plan.el`, `kargu-chat-plan--dispatch` (lines 90-103) calls `(kargu-mode-prepare 'agent ...)` and then executes `(kargu-chat-prompt ...)` via `kargu-chat-plan--start-ready`.
  2. `kargu-chat-prompt` in `kargu/chat.el` is a chat UI command rather than an explicit application coordinator port. It lacks an explicit application claim token handshake.
  3. When an approved plan starts, if the application is busy or an active run is in flight, the preflight currently checks `(kargu-application-work-active-p)`, but does not acquire a formal `kargu-application-claim` (Contract 1) before altering mode and dispatching.

---

## 3. Detailed Architecture Blueprint for Worker H

### 3.1 Component A: Provider / Model Catalog & Metadata Service

#### 3.1.1 Service Definition (`kargu/providers/catalog.el` and `kargu/api/catalog.el`)
Define an explicit Catalog & Metadata Service struct:

```elisp
(cl-defstruct (kargu-catalog-service
               (:constructor kargu-catalog-service--create))
  "Owned catalog and metadata service managing generations, caches, and refusals."
  (id (format "catalog-%s" (kargu-random-uuid)) :read-only t)
  (generations (make-hash-table :test #'equal))
  (live-cache (make-hash-table :test #'equal))
  (refusals (make-hash-table :test #'equal))
  (prefetched (make-hash-table :test #'equal))
  (revision 0))
```

Define accessor and lifecycle functions:
- `(kargu-catalog-service-instance (&optional service))`
- `(kargu-catalog-service-reset (&optional service))`
- `(kargu-catalog-service-revision (&optional service))`

#### 3.1.2 Catalog Generation & Cache Disciplinary Rules
- `generations`: incremented per provider request. Responses matching an older generation are ignored for shared cache updates, preserving single-delivery and newest-wins semantics.
- `live-cache`: maps `provider` (string) -> list of clean model ID strings.
  - Distinguish `:unknown` (not yet queried), `nil` / `'()` (successful empty catalog), and failure (error delivered to callback).
- `refusals`: maps `(provider . model-id)` -> `t`. When provider signals tool refusal, it is remembered in the service instance; `kargu-catalog-service-forget-refusals` clears them.
- `revision`: monotonic counter incremented on every:
  - `kargu-model-store-put`
  - `kargu-model-store-set-property`
  - `kargu-model-store-retain`
  - `kargu-model-mark-tools-refused`
  - `kargu-model-forget-tools-refusals`

#### 3.1.3 Binding Capabilities to Connection Snapshot (`kargu/config/connection.el`)
When `kargu-connection-resolve-async` constructs `kargu-connection-snapshot`:
Resolve full model capabilities at snapshot time:
```elisp
(let* ((tools-p (kargu-model-supports-tools-p mname pname-lower))
       (reason-p (kargu-model-supports-reasoning-p mname pname-lower))
       (efforts (kargu-model-reasoning-efforts mname pname-lower))
       (ctx-win (kargu-model-context-window mname pname-lower))
       (max-out (kargu-model-get-prop mname "max-output" pname-lower))
       (cat-rev (kargu-catalog-service-revision))
       (caps (or capabilities
                 (list :tools tools-p
                       :stream (kargu-provider-format-stream-p wire-format)
                       :reasoning reason-p
                       :reasoning-efforts efforts
                       :context-window ctx-win
                       :max-output max-out
                       :catalog-revision cat-rev))))
  (kargu-connection-snapshot--create
   :provider pname-lower
   :model mname
   :endpoint endpoint
   :wire-format wire-format
   :capabilities caps
   :config-revision captured-rev
   :credential-scope scope))
```
**Invariant**: Consumers of `kargu-connection-snapshot` during an active run (loop, tool gate, transport) MUST inspect `(plist-get (kargu-connection-snapshot-capabilities snapshot) :tools)`, etc., and must NEVER re-query mutable `kargu-model-supports-tools-p` during an active run.

#### 3.1.4 Clean Semantic Distinctions
- `off`: `(equal (downcase effort) "off")` -> stored as `nil`, effectively disabling reasoning parameters.
- `none`: model metadata has no reasoning effort list (`:reasoning-efforts` is `nil`); displayed as `"none"` in inspector labels.
- `inherit`: fallback to configuration default (`kargu-reasoning-effort`) or session context when unspecified.
- `successful-empty`: API returned 200 with `[]` or `{"data": []}`. Recorded as `'()` in `live-cache`. `kargu-selection-models-known-p` returns non-nil (known to be empty), preventing redundant network polling.

---

### 3.2 Component B: Owned View & Selection

#### 3.2.1 Selection State Decoupling (`kargu/selection.el` & `kargu/chat/select.el`)
- Selection context belongs strictly to `kargu-session` (`kargu/core/session.el`).
- Functions in `kargu/chat/select.el` must accept an explicit `chat-buffer` or derive it from the caller rather than scanning `(buffer-list)`.
- When continuing after model selection (`kargu-api-select--continue`):
  Verify `(eq owner (kargu-session-context buf))` and `(eq selection (kargu-selection-context owner))`. If superseded, abort silently without stealing focus.

#### 3.2.2 Bounded and Coalesced UI Streaming (`kargu/chat/stream.el`)
Replace raw synchronous insertion on every delta with a bounded render queue:

```elisp
(defvar-local kargu-chat--render-queue nil
  "FIFO list of (TEXT . KIND) chunks awaiting insertion in this chat buffer.")

(defvar-local kargu-chat--render-timer nil
  "Active timer draining `kargu-chat--render-queue'.")

(defcustom kargu-chat-render-coalesce-limit 64
  "Maximum queue length before consolidating adjacent chunks."
  :type 'integer
  :group 'kargu-ui)

(defun kargu-chat--on-delta (text &optional kind)
  "Queue streamed TEXT of KIND in the run's chat buffer, scheduling coalesced render."
  (save-match-data
    (let ((buffer (kargu-chat-output-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (kargu-chat--enqueue-delta text kind))))))

(defun kargu-chat--enqueue-delta (text kind)
  "Append TEXT and KIND to buffer render queue, coalescing if threshold reached."
  (when (and (stringp text) (not (string-empty-p text))
             (not kargu-chat--preamble-dropped))
    (setq kargu-chat--render-queue (nconc kargu-chat--render-queue (list (cons text kind))))
    (when (> (length kargu-chat--render-queue) kargu-chat-render-coalesce-limit)
      (kargu-chat--coalesce-render-queue))
    (unless (timerp kargu-chat--render-timer)
      (setq kargu-chat--render-timer
            (run-with-timer 0.02 nil #'kargu-chat--drain-render-queue (current-buffer))))))

(defun kargu-chat--coalesce-render-queue ()
  "Consolidate consecutive chunks of identical KIND in `kargu-chat--render-queue'."
  (let ((coalesced nil)
        (current-text "")
        (current-kind nil))
    (dolist (item kargu-chat--render-queue)
      (let ((txt (car item))
            (knd (cdr item)))
        (if (and current-kind (eq knd current-kind))
            (setq current-text (concat current-text txt))
          (when current-kind
            (push (cons current-text current-kind) coalesced))
          (setq current-text txt
                current-kind knd))))
    (when current-kind
      (push (cons current-text current-kind) coalesced))
    (setq kargu-chat--render-queue (nreverse coalesced))))

(defun kargu-chat--drain-render-queue (buffer)
  "Drain queued streaming chunks into BUFFER in a single UI transaction."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kargu-chat--render-timer nil)
      (when kargu-chat--render-queue
        (let ((queue kargu-chat--render-queue))
          (setq kargu-chat--render-queue nil)
          (dolist (item queue)
            (kargu-chat--stream-delta (car item) (cdr item))))))))

(defun kargu-chat-flush-stream ()
  "Immediately drain pending queue and render trailing incomplete markers."
  (when (timerp kargu-chat--render-timer)
    (cancel-timer kargu-chat--render-timer)
    (setq kargu-chat--render-timer nil))
  (when kargu-chat--render-queue
    (let ((queue kargu-chat--render-queue))
      (setq kargu-chat--render-queue nil)
      (dolist (item queue)
        (kargu-chat--stream-delta (car item) (cdr item)))))
  (unless (string-empty-p kargu-chat--thought-pending)
    (kargu-chat--insert-stream-text kargu-chat--thought-pending)
    (setq kargu-chat--thought-pending "")))
```

#### 3.2.3 Stop Responsiveness & Stream Cancellation
- In `kargu-chat-stop`:
  Cancel `kargu-chat--render-timer` immediately.
  Empty `kargu-chat--render-queue`.
  Call `kargu-loop-stop` (or application release).
  Replace running banner with idle prompt immediately via `kargu-chat--ensure-idle-prompt`.
- Stream insertion in `kargu/chat/transcript.el` (`kargu-chat-insert-into`) wraps text insertion in `(save-restriction (widen) ...)` and preserves point and window points via `kargu-chat--compute-window-follow-states`.
- Point in the prompt input area (`>= kargu-chat--prompt-marker`) remains completely unaffected by arriving stream chunks, allowing continuous editing and IME input during generation.

---

### 3.3 Component C: Scoped Confirmation Service (`kargu/ui/confirm.el`)

#### 3.3.1 Handle and View Scoping
Instead of a single global list `kargu-confirm--pending`, structure confirmation requests by handle:

```elisp
(cl-defstruct (kargu-confirm-handle (:constructor kargu-confirm-handle--create))
  "Scoped handle for a pending confirmation request."
  (id (format "cfm-%s" (kargu-random-uuid)) :read-only t)
  (buffer nil :read-only t)
  (session-id nil :read-only t)
  (job-id nil :read-only t)
  (req nil))

(defvar kargu-confirm--pending-table (make-hash-table :test #'equal)
  "Table mapping confirmation ID string to `kargu-confirm-handle'.")

(defvar-local kargu-confirm--buffer-requests nil
  "List of active `kargu-confirm-handle' instances owned by this buffer.")
```

#### 3.3.2 Scoped Settle & Buffer Teardown
- `(kargu-confirm-cancel-scoped (scope))` cancels only confirmations belonging to `scope` (which can be a buffer, session-id, or handle).
- `(kargu-confirm-dismiss-all (&optional buffer))` cancels only requests for `buffer` if provided, avoiding foreign session disruption.
- Buffer `kill-buffer-hook` (`kargu-confirm--cancel-buffer`):
  Iterates over `kargu-confirm--buffer-requests`, settling each with `:cancel`. Leaves other buffers' requests untouched.
- Headless execution:
  When `noninteractive` or headless:
  `(funcall on-decision default-action)` immediately evaluates without enqueuing or allocating handles.

---

### 3.4 Component D: Plan Dispatcher & Resource Teardown

#### 3.4.1 Application Port Dispatch (`kargu/plan/dispatch.el` & `kargu/chat/plan.el`)
The plan dispatcher must invoke the Application Coordinator contract:

```elisp
(defun kargu-chat-plan--dispatch (record plan-text complete)
  "Dispatch RECORD's PLAN-TEXT using the application coordinator claim."
  (let ((origin (kargu-plan-record-origin record)))
    (with-current-buffer origin
      (let* ((app (kargu-application-context))
             (run-id (format "plan-run-%s" (kargu-random-uuid)))
             (claim-res (kargu-application-claim app run-id 'agent (kargu-session-id origin))))
        (if (kargu-err-p claim-res)
            (user-error "Kargu: cannot dispatch plan: %s" (kargu-result-error-message claim-res))
          (let* ((claim (kargu-unwrap claim-res))
                 (start (kargu-chat-plan--start
                         :record record
                         :session (kargu-session-context)
                         :selection (kargu-selection-context)
                         :mode (kargu-state-mode)
                         :revision (kargu-session-mode-revision (kargu-session-context))
                         :view-tick (with-current-buffer (kargu-plan-record-buffer record)
                                      (buffer-chars-modified-tick))
                         :draft (kargu-chat-plan--draft)
                         :text plan-text
                         :complete (lambda (success err)
                                     (unless success
                                       (kargu-application-release app claim))
                                     (funcall complete success err)))))
            (kargu-mode-prepare
             'agent
             (lambda (mode err)
               (let ((failure (kargu-chat-plan--start-ready start mode err)))
                 (when failure
                   (kargu-application-release app claim)))))))))))
```

#### 3.4.2 Resource Cleanup on Buffer Close (`kargu/plan/store.el`)
When an origin buffer or review buffer closes:
- `kargu-plan--forget-buffer`:
  - Cancels active async dispatch task via `kargu-plan-cancel-dispatch`.
  - Removes buffer-local hooks (`kill-buffer-hook`, `change-major-mode-hook`).
  - Sets state to `:cancelled`.
  - Detaches references from both origin and review buffers.
- Model pickers and Company sessions are cleaned up cleanly via `kargu-api-select--cleanup`.

---

## 4. Test Suite Specification (`tests/test-view-lifetime.el`)

The new test suite `tests/test-view-lifetime.el` verifies the end-to-end lifetime and isolation guarantees of Package H:

```elisp
;;; test-view-lifetime.el --- View lifetime and isolation contracts -*- lexical-binding: t; -*-

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu)
(require 'kargu/chat)
(require 'kargu/chat/select)
(require 'kargu/chat/stream)
(require 'kargu/ui/confirm)
(require 'kargu/plan)

(ert-deftest test-view-lifetime-dual-project-isolation ()
  "Verify two projects/views have isolated selections, roots, and markers.")

(ert-deftest test-view-lifetime-focus-safety-on-delayed-catalog ()
  "Verify delayed catalog callback does not steal focus or corrupt foreign buffer.")

(ert-deftest test-view-lifetime-stream-preserves-point-narrowing-ime ()
  "Verify streaming updates preserve prompt point, narrowed views, and IME text.")

(ert-deftest test-view-lifetime-coalesced-stream-responsive-stop ()
  "Verify render queue coalesces heavy delta bursts and Stop is immediately responsive.")

(ert-deftest test-view-lifetime-confirmation-scoped-cancellation ()
  "Verify closing one chat buffer cancels only its own confirmations.")

(ert-deftest test-view-lifetime-model-service-isolation ()
  "Verify connection snapshot capabilities remain immutable across metadata edits.")

(ert-deftest test-view-lifetime-buffer-close-resource-cleanup ()
  "Verify closing review buffer cleanly releases tasks, hooks, and plan records.")
```

---

## 5. Formal Models & TLC Verification Plan

- `proof/KarguSelection.tla`:
  - Run: `bash proof/run_tlc.sh --selection`
  - Invariants: `TypeOK`, `Safety_OwnedAdmission`, `Safety_DiscardedCannotApply`, `Safety_FrozenSettings`.
  - Result: 640,440 distinct states checked, 0 errors, PASS.
- `proof/KarguPlan.tla`:
  - Run: `bash proof/run_tlc.sh --plan`
  - Invariants: `TypeOK`, `Safety_OwnedDispatch`, `Safety_NoResurrectedDecisions`, `Safety_OneClaimPerOwner`, `Safety_NoRejectedDispatch`.
  - Result: 72,313 distinct states checked, 0 errors, PASS.
- **Worker H Verification Invariant**: No changes to `KarguSelection.tla` or `KarguPlan.tla` state transitions are required unless a bug in the model is uncovered. If updated, TLC must be re-run and pass with 0 errors.

---

## 6. Worker H Implementation Blueprint & Step-by-Step Sequence

Worker H should implement the package in 4 distinct steps:

### Step 1: Catalog & Metadata Service
- In `kargu/api/catalog.el`, `kargu/providers/catalog.el`, and `kargu/models/store.el`:
  - Move generation tracking, live cache, and refusal storage into `kargu-catalog-service`.
  - Add revision counter tracking to `kargu-model-store-*`.
  - In `kargu/config/connection.el`: bind resolved capabilities and catalog revision into `kargu-connection-snapshot`.
- Verification: run `tests/test-model-store.el`, `tests/test-metadata.el`, `tests/test-dynamic-models.el`.

### Step 2: Owned View & Selection + Bounded Streaming Queue
- In `kargu/selection.el` and `kargu/chat/select.el`:
  - Decouple from global buffer searching; enforce explicit session/buffer parameters.
- In `kargu/chat/stream.el` and `kargu/chat/transcript.el`:
  - Add bounded, coalescing render queue (`kargu-chat--render-queue`, `kargu-chat--render-timer`, `kargu-chat-flush-stream`).
  - Guarantee Stop responsiveness and cursor/narrowing/IME safety.
- Verification: run `tests/test-selection.el`, `tests/test-chat.el`, `tests/test-chat-state.el`.

### Step 3: Scoped Confirmations & Plan Dispatcher
- In `kargu/ui/confirm.el`:
  - Scope pending requests by buffer/handle; update `kill-buffer-hook` and scoped dismiss.
- In `kargu/chat/plan.el` and `kargu/plan/dispatch.el`:
  - Connect plan dispatch to `kargu-application-claim` port.
  - Preserve claim, approved revision, draft state, and clean teardown on buffer close.
- Verification: run `tests/test-confirm.el`, `tests/test-plan.el`, `tests/test-plan-async.el`.

### Step 4: Test Suite & Comprehensive Gate Verification
- Create `tests/test-view-lifetime.el` with the 7 designated integration test cases.
- Run complete ERT test suite (1052+ tests) with zero failures.
- Run `byte-compile-file` on all modified files with `(setq byte-compile-error-on-warn t)`.
- Run TLC checks (`proof/run_tlc.sh --selection`, `proof/run_tlc.sh --plan`).
- Ensure no leftover `.elc` files in the repository.
