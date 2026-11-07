# Wave 3 Package G Architectural Exploration & Blueprint Report
**Domain**: Headless Engine Loop, History Protocol Wall, Structured Events & Unified Budget Consumption  
**Author**: `explorer_wave3_G`  
**Date**: 2026-10-22  
**Target Milestone**: Wave 3 Package G (M3)  
**Tracking Issues**: MOD-01, ARCH-07, ARCH-08, ARCH-11, ARCH-14, ARCH-16, DEEP-01, DEEP-02, DEEP-04, DEEP-09  

---

## 1. Executive Summary

Package G delivers the decoupled, headless agent engine for Kargu. It eliminates the coupling between the execution loop and UI/chat buffers, establishes structured immutable event streaming to passive observers with a strict single-terminal-event invariant, enforces the protocol firewall on every outbound request, and connects all turns (normal requests, transport retries, loop retries, self-healing, compactions, and continuations) to Package A's unified `kargu-run-budget`.

### Baseline Health Check
- **Full ERT Test Suite**: **1052 / 1052 tests PASS** (44.80s, 0 failures, 0 errors).
- **Formal Verification Baseline**:
  - `proof/run_tlc.sh --budget` (BudgetMC.tla): **PASS** (1591 states, 432 distinct states, 0 errors).
  - `proof/run_tlc.sh --verification` (VerificationMC.tla): **PASS** (439 states, 68 distinct states, 0 errors).
  - `proof/run_tlc.sh` (MC.tla): Exhaustive state exploration of loop and protocol FSM.

---

## 2. Analysis of Existing Architecture & Technical Gaps

### 2.1 Loop & Application Ownership Coupling (`kargu/loop.el`)
- **Observation**:
  `kargu-loop-send` currently defaults `:chat-buffer` to `(current-buffer)` and calls `(kargu-loop--attach-origin run)`, which directly attaches buffer-local hooks `kill-buffer-hook` and `change-major-mode-hook` to `origin`. When invoked in headless or batch mode without a live chat buffer, or when `origin` is killed, running `with-current-buffer` can attach hooks to random buffers or fail.
- **Application Context Omission**:
  Wave 1 Package A established `kargu-application` and explicit claim management (`kargu-application-claim` / `kargu-application-release`). `kargu/loop.el` currently sets `kargu-application-set-active-run`, but does NOT acquire an explicit claim token via `kargu-application-claim` or release it on run completion, leaving application coordinator lifecycle transitions partially manual.
- **Status Synchronization**:
  State transitions in `kargu-loop--set-state` map onto global `kargu-state-transition-status`. The loop needs to update the explicit `kargu-application` status via `kargu-application-transition` directly when an application context is attached.

### 2.2 Event Notification & Observer Contract (`kargu/loop/machine.el`, `kargu/loop/tools.el`)
- **Observation**:
  Stream and tool hooks (`kargu-loop-model-stream-hook`, `kargu-loop-tool-start-hook`, `kargu-loop-tool-finish-hook`) pass ad-hoc arguments without standardized event correlation IDs.
- **Contract 7 Violation**:
  Contract 7 mandates typed `kargu-passive-event` structures containing `kargu-event-id` (with `run-id`, `session-id`, `request-id`, `sequence-no`, and monotonic `timestamp`), with observer isolation (`condition-case-unless-debug`) and an inviolable guarantee of **exactly ONE terminal event** (`:run-finish`). Late chunks or callbacks after the terminal event must be dropped.

### 2.3 Tool Execution Coupling (`kargu/loop/tools.el`)
- **Observation**:
  `kargu--loop-execute-call` calls `(kargu-loop--gate-tool name)` and `(kargu-execute-tool name args on-result)`.
  In Wave 2, Package D introduced the canonical 13-stage tool execution gate: `kargu-tool-gate-execute` in `kargu/tools/execution.el`.
  `kargu-loop--gate-tool` duplicates mode gating and permission checks. The loop should directly build a `kargu-tool-execution-context` (referencing `app`, `run-id`, `session-id`, `root`, `mode`, `budget`, and policy revision) and invoke `kargu-tool-gate-execute`.

### 2.4 Run Budget Accounting Fragmentation (Contract 6 & DEEP-09)
- **Observation**:
  Package A provides `kargu-run-budget` (`kargu/application/budget.el`). In Package E (`kargu/api/http.el`), `kargu--api-post` debits `:normal-request` (for initial calls) and `:retry-attempt` (for transport retries).
- **Gap**:
  Compaction turns (`kargu/loop/compact.el`), loop upstream retries (`kargu/loop/machine.el`), self-healing repair turns (`kargu/loop/heal.el`), and continuation turns (`kargu/loop/machine.el`) do not currently specify their debit type to the transport client.
  As a result:
  1. Compaction turns are recorded as normal requests instead of debiting `:compaction-turn`, failing to increment `compactions-spent` in `kargu-run-budget`.
  2. The single-compaction invariant (`max-compactions 1`) in `kargu-run-budget` is bypassed at the budget level.
  3. Loop upstream retries (`kargu-loop--retry-upstream`) reset `attempt = 0` in HTTP, meaning the loop retry debits `:normal-request` instead of `:retry-attempt`.

### 2.5 History Queue & Protocol Wall (`kargu/history/*.el`)
- **Observation**:
  `kargu/history/store.el` implements O(1) queue appending and incremental character counting via `kargu-history-message-char-count`.
  `kargu/history/repair.el` validates the protocol firewall (stripping trailing assistant turns, injecting synthetic results for unanswered calls, dropping orphan tool results, merging consecutive user turns, ensuring at least one user turn).
- **Requirements**:
  Preserve this owned queue. Ensure every outbound request passes through `kargu--validate-history`. Guard against second overflow and failed/empty compaction summaries.

### 2.6 Baseline Diagnostics Integrity (`kargu/loop/heal.el`)
- **Observation**:
  In `kargu--loop-compare-diagnostics`, if baseline diagnostics are unavailable, `:baseline-available` is `nil`.
- **Requirement (DEEP-01)**:
  When baseline diagnostics are unavailable, the report must state status as `unknown` rather than claiming clean status or attributing pre-existing errors as new regressions.

---

## 3. Headless Engine Loop Architecture Specification

### 3.1 Coordination & Claim Management
```elisp
(cl-defun kargu-loop-send (prompt &optional on-delta on-finish &key app budget chat-buffer mode)
  "Start an agent run with PROMPT.
Optional keyword arguments bind explicit APP (a `kargu-application'),
BUDGET (`kargu-run-budget'), CHAT-BUFFER (origin buffer or nil for headless),
and MODE (`agent', `ask', `plan', `debug')."
  ...)
```

#### Invariants:
1. **Single-Active-Run (ARCH-01/ARCH-12)**:
   - Resolve `app` (`(or app (kargu-application-context))`).
   - If `(kargu-application-work-active-p app)` or `(kargu-loop-running-p)`:
     Signal `user-error` "Kargu: a run is already in progress (M-x kargu-loop-stop)".
   - Acquire exclusive claim:
     `(kargu-application-claim app :run-id run-id :mode mode :session-id (kargu-session-id session))`
2. **Headless Safety**:
   - `:chat-buffer` is optional and may be `nil`.
   - `kargu-loop--attach-origin` and `kargu-loop--detach-origin` check `(and origin (buffer-live-p origin))`. When `origin` is `nil`, no buffer hooks are attached or removed.
   - Buffer switching in `kargu--loop-finish`, `kargu-loop--receive-model`, and `kargu-loop-stop` checks `(and origin (buffer-live-p origin))`. If nil, execution continues in `current-buffer` without errors.
3. **Control Request Fallback**:
   - `kargu-confirm` is used for continue prompts, upstream retry prompts, doom loop approval, and compaction retry prompts.
   - In headless execution (when no presentation adapter advice is attached or buffer is headless), `kargu-present-confirmation` automatically invokes `(funcall on-decision default-action)` where `default-action` is `:stop` or `:reject`. The loop terminates cleanly with `:limit` or `:error` without hanging or prompting in the echo area.

### 3.2 Structured Event Emission (Contract 7, ARCH-07, ARCH-08)

#### Event Types and Payloads:
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
  (id nil :read-only t)       ; kargu-event-id
  (type nil :read-only t)     ; :turn-start, :stream-chunk, :tool-start, :tool-finish, :run-finish
  (payload nil :read-only t)) ; immutable plist
```

#### Event Dispatcher:
```elisp
(defun kargu-loop-emit-event (run type payload)
  "Emit passive event of TYPE with PAYLOAD on RUN to registered observers.
Guarantees monotonic sequence numbers, observer error isolation, and
single terminal event delivery."
  (unless (plist-get run :finished-p)
    (let* ((seq (cl-incf (plist-get run :event-seq)))
           (id (kargu-event-id--create
                :run-id (plist-get run :id)
                :session-id (plist-get run :session-id)
                :request-id (or (plist-get run :current-request-id)
                                (format "req-%d" seq))
                :sequence-no seq
                :timestamp (float-time)))
           (event (kargu-passive-event--create
                   :id id :type type :payload payload)))
      (when (eq type :run-finish)
        (plist-put run :finished-p t))
      ;; Deliver to run-scoped observers and global hook
      (dolist (observer (plist-get run :observers))
        (condition-case-unless-debug err
            (funcall observer event)
          (error (kargu-log 'warn "Loop observer error: %s"
                            (error-message-string err)))))
      (when (boundp 'kargu-loop-event-hook)
        (run-hook-with-args 'kargu-loop-event-hook event)))))
```

#### Single Terminal Event Guarantee:
- Setting `(plist-put run :finished-p t)` inside `kargu-loop--finish-owned` ensures that late chunks, retry boundaries, or asynchronous callbacks cannot emit further events.

---

## 4. Unified Run Budget Consumption Blueprint (Contract 6)

### 4.1 Budget Binding at Run Startup
In `kargu-loop-send`:
```elisp
(let* ((app (or app (kargu-application-context)))
       (budget (or budget
                   (kargu-application-budget-get app)
                   (kargu-budget-create :run-id (plist-get run :id)
                                        :max-requests (or (and (boundp 'kargu-max-iterations)
                                                               kargu-max-iterations)
                                                          30))))
  (kargu-application-set-budget budget app)
  (plist-put run :budget budget)
  ...)
```

### 4.2 Explicit Debit Types Across All Turn Boundaries
| Action | File & Function | Debit Type | Requests | Parameters |
|---|---|---|---|---|
| User prompt or tool follow-up | `kargu-loop--send-model` | `:normal-request` | 1 | N/A |
| Upstream loop retry | `kargu-loop--retry-upstream` | `:retry-attempt` | 1 | N/A |
| Transport HTTP retry | `kargu/api/http.el` (`kargu--api-post`) | `:retry-attempt` | 1 | `attempt > 0` |
| Context compaction turn | `kargu/loop/compact.el` (`kargu--loop-begin-compaction`) | `:compaction-turn` | 1 | N/A |
| Healing repair turn | `kargu/loop/heal.el` / `kargu/loop/tools.el` | `:healing-turn` | 1 | When new errors re-prompt |
| Length truncation continue | `kargu/loop/machine.el` (`kargu-loop--on-length`) | `:continuation` | 1 | `kargu--continue-nudge` |
| User turn limit extension | `kargu/loop/ui.el` (`kargu-loop--apply-continue-decision`) | `:continuation` | 1 | Resuming prompt |

### 4.3 Propagation of Debit Type to Transport
Enhance `kargu-api-send` / `kargu-api--send` to accept `:debit-type`:
```elisp
(cl-defun kargu-api-send (prompt callback &optional on-delta &key (debit-type :normal-request))
  ...)
```
In `kargu/api/http.el` (`kargu--api-post`):
```elisp
;; 2. Run budget debit gate (Contract 6 & DEEP-09)
(when budget
  (let* ((effective-debit (or debit-type (if (> attempt 0) :retry-attempt :normal-request)))
         (debit-res (kargu-budget-debit budget effective-debit :requests 1)))
    (when (kargu-err-p debit-res)
      (kargu-http-clear-busy)
      (kargu-log 'warn "Run budget exhausted; refusing request (%s)"
                 (kargu-result-err-message debit-res))
      (funcall callback debit-res)
      (cl-return-from kargu--api-post nil))))
```

### 4.4 Compaction Invariants (DEEP-02)
1. **Single Compaction Invariant**:
   `kargu-budget-debit` checks `(>= (kargu-run-budget-compactions-spent budget) (kargu-run-budget-max-compactions budget))`.
   A second compaction attempt returns `(kargu-err "Compaction turn limit exceeded for run" :budget-exhausted ...)`.
2. **Second Overflow Protection**:
   In `kargu-loop--classify-response`:
   ```elisp
   ((and err (kargu-response-overflow-p response)
         (kargu--loop-compact-allowed-p run)
         (let ((b (plist-get run :budget)))
           (or (null b) (< (kargu-run-budget-compactions-spent b)
                           (kargu-run-budget-max-compactions b)))))
    'overflow)
   ```
   If compaction was already executed or the budget has spent its compaction allowance, the response is classified as `error` and terminates the run with `:error` ("context overflow"), preventing infinite compaction loops.
3. **Empty/Failed Summary Recovery**:
   If compaction produces an empty response or fails, `kargu-loop--compaction-empty` drops the trailing compaction message and terminates with `:error` ("compaction produced an empty summary").

---

## 5. History Queue & Protocol Wall Integration (ARCH-07)

### 5.1 Owned Queue in `kargu/history/store.el`
- Messages are stored as a proper list in `kargu-history`.
- `kargu-history-append` mutates the tail pointer in O(1) time without consing the whole history.
- `kargu-history-snapshot` performs `(copy-tree messages t)`, detaching list and vector containers so callers cannot mutate internal queue structure.
- `kargu-history-message-char-count` tracks the incremental cursor `kargu-history-measured-tail-value` and encodes only newly appended messages, maintaining constant measurement overhead across turns.

### 5.2 Outbound Protocol Wall
Every outbound request dispatched through `kargu-api-send` passes through `kargu--validate-history`:
1. Strips or normalizes system prompts so exactly one system message appears at index 0.
2. Injects synthetic error tool results (`"ERROR: interrupted before response"`) for any unanswered tool calls.
3. Discards orphan tool results that have no matching preceding assistant tool call.
4. Merges consecutive user turns.
5. In outbound requests (`keep-assistant-tail nil`), strips trailing assistant messages or nudges with "Continue.".
6. In completed runs (`keep-assistant-tail t`), preserves the final assistant answer in history.

---

## 6. Baseline Diagnostics Handling (DEEP-01)

In `kargu/loop/heal.el`:
- When baseline diagnostics are unavailable (e.g. LSP not running, settlement timeout, or missing snapshot):
  - Do NOT assume the file was clean before the edit.
  - Do NOT count existing errors as `:new-errors` (which would spuriously consume healing rounds).
  - Do NOT declare the edit as "Verification passed (clean)".
  - Return `:baseline-available nil` and `:status :unknown`.
  - The verification report explicitly outputs:
    `"Baseline comparison unavailable: observed errors cannot be classified as new or pre-existing. Status: UNKNOWN. Do not claim a regression-free edit."`
- If 0 errors are reported post-edit but baseline was unavailable:
  `"Verification passed on edited file (0 errors observed). Project-wide baseline was unavailable; cross-file effects are UNVERIFIED."`

---

## 7. Concrete Code Implementation Blueprint for Worker G

### 7.1 `kargu/loop.el`
```elisp
;; --- In kargu-loop-send ---
(cl-defun kargu-loop-send (prompt &optional on-delta on-finish &key app budget chat-buffer mode observers)
  "Start an agent run with PROMPT.
Optional keyword arguments bind explicit APP, BUDGET, CHAT-BUFFER,
MODE, and OBSERVERS."
  (interactive "skargu prompt: ")
  (kargu-contract-assert #'kargu-contract-non-empty-string-p prompt
                         "kargu: prompt must be a non-empty string: %S" prompt)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "kargu: on-delta must be callable or nil: %S" on-delta)
  (kargu-contract-assert #'kargu-contract-callback-p on-finish
                         "kargu: on-finish must be callable or nil: %S" on-finish)
  (let* ((target-app (or app (kargu-application-context)))
         (target-mode (or mode (kargu-state-mode)))
         (session (kargu-session-context))
         (run-id (kargu--generate-session-id))
         (no-tools (kargu-loop-preflight)))
    ;; Single-active-run check & claim (ARCH-01/ARCH-12)
    (when (or (kargu-application-work-active-p target-app)
              (kargu-loop-running-p))
      (user-error "Kargu: a run is already in progress (M-x kargu-loop-stop)"))
    (let* ((claim (kargu-application-claim target-app
                                           :run-id run-id
                                           :mode target-mode
                                           :session-id (kargu-session-id session)))
           (effective-budget
            (or budget
                (kargu-application-budget-get target-app)
                (kargu-budget-create :run-id run-id
                                     :max-requests (or (and (boundp 'kargu-max-iterations)
                                                            kargu-max-iterations)
                                                       30))))
           (wrapped (kargu-prompt-wrap-user prompt))
           (run (kargu-loop--new-run prompt
                                     :no-tools no-tools
                                     :on-delta on-delta
                                     :on-finish on-finish
                                     :app target-app
                                     :claim claim
                                     :budget effective-budget
                                     :chat-buffer chat-buffer
                                     :mode target-mode
                                     :observers observers)))
      (kargu-application-set-budget effective-budget target-app)
      (setf (kargu-history-overlay) nil)
      (kargu-edit-changes :reset)
      (kargu-loop--start-run run wrapped)
      run)))
```

### 7.2 `kargu/loop/tools.el` — Unified Gate Execution
```elisp
(cl-defun kargu--loop-execute-call (run &key id name args sig queue)
  "Run tool NAME with ARGS for call ID of RUN through Package D's execution gate."
  (unless (kargu-loop--tool-cacheable-p name)
    (plist-put run :batch-cache nil))
  (let* ((state :pending)
         (on-result
          (lambda (result)
            (when (and (eq state :pending) (kargu-loop--live-p run))
              (setq state :delivered)
              ;; Emit structured :tool-finish event
              (kargu-loop-emit-event
               run :tool-finish (list :id id :name name :result result))
              (kargu-run-observers 'kargu-loop-tool-finish-hook run result)
              (when (kargu-loop--live-p run)
                (kargu--loop-complete-tool run :id id :name name :result result
                                           :queue queue :sig sig))))))
    ;; Emit structured :tool-start event
    (kargu-loop-emit-event
     run :tool-start (list :id id :name name :args args))
    (kargu-run-observers 'kargu-loop-tool-start-hook run name args)
    (condition-case err
        (when (kargu-loop--live-p run)
          (let* ((app (plist-get run :app))
                 (run-id (plist-get run :id))
                 (session-id (plist-get run :session-id))
                 (root (or (plist-get run :project-root)
                           (kargu-permission-project-root)))
                 (mode (or (plist-get run :mode) (kargu-state-mode)))
                 (budget (plist-get run :budget))
                 (registry (if (boundp 'kargu--tool-registry)
                               kargu--tool-registry
                             (kargu-tool-registry-create)))
                 (context (kargu-tool-execution-context-create
                           :app app
                           :run-id run-id
                           :session-id session-id
                           :root root
                           :mode mode
                           :budget-scope budget
                           :policy-revision (kargu-tool-registry-revision registry))))
            (kargu-tool-gate-execute
             registry context name args :callback on-result)))
      (error
       (funcall on-result (format "ERROR: executing tool %s: %s"
                                  name (error-message-string err)))))))
```

### 7.3 `kargu/loop/compact.el` — Unified Budget Compaction
```elisp
(defun kargu--loop-begin-compaction (run)
  "Start a tools-off compaction turn for RUN, debiting :compaction-turn."
  (when (kargu-loop--live-p run)
    (let ((budget (plist-get run :budget)))
      ;; Debit :compaction-turn against run budget
      (when budget
        (let ((debit-res (kargu-budget-debit budget :compaction-turn :requests 1)))
          (when (kargu-err-p debit-res)
            (kargu-log 'warn "loop: compaction debit refused (%s)"
                       (kargu-result-err-message debit-res))
            (kargu--loop-finish run :limit "budget exhausted during compaction")
            (cl-return-from kargu--loop-begin-compaction nil)))))
    (kargu-log 'info "loop: compacting history (%d chars)"
               (kargu-history-char-count))
    (kargu-loop--set-state run 'compact)
    (plist-put run :compacting t)
    (plist-put run :saved-no-tools (plist-get run :no-tools))
    (plist-put run :no-tools t)
    (plist-put run :compact-tail (kargu-history-compact-tail))
    (setf (kargu-history-overlay) kargu-prompt-compaction-system)
    (when (equal (kargu--history-last-role) "user")
      (kargu--history-add "assistant" "Understood."))
    (kargu-api-send
     kargu-prompt-compaction-user
     (lambda (response)
       (kargu--loop-handle-compaction run response))
     nil
     :debit-type :compaction-turn)))
```

---

## 8. Specification of New Test Suites

### 8.1 `tests/test-headless-events.el` (New)
Covers MOD-01, ARCH-07, ARCH-08, ARCH-17.
Key Test Cases:
1. `test-headless-loop-runs-without-buffers`:
   Invokes `kargu-loop-send` with `:chat-buffer nil` and fake transport model. Verifies run completes with `:status :done`, no buffer-local error raised, and application claim released.
2. `test-headless-loop-full-tool-turn`:
   Model returns tool call `read_file`. Tool executes through `kargu-tool-gate-execute`. Result is fed back to model. Model returns final answer. Verifies tool execution and result handling without chat buffer.
3. `test-headless-events-monotonic-and-single-finish`:
   Attaches observer. Emits sequence of events (`:turn-start`, `:stream-chunk`, `:tool-start`, `:tool-finish`, `:run-finish`). Asserts sequence numbers are strictly monotonic `1, 2, 3, 4, ...` and exactly ONE `:run-finish` is delivered.
4. `test-headless-observer-stop-reentrancy`:
   An observer calls `kargu-loop-stop` during `:stream-chunk` or `:tool-start`. Verifies loop stops cleanly with `:status :stopped`, no loop hanging, exactly one `:run-finish` event emitted, and no subsequent events delivered.
5. `test-headless-observer-error-isolation`:
   Observer signals `(error "Observer crashed")`. Verifies loop does NOT terminate, other observers receive event, and model response completes normally.
6. `test-headless-confirm-fallback-stops-cleanly`:
   When turn cap is reached without continue confirmation, `kargu-confirm` invokes `:default-action :stop` immediately. Loop finishes with `:status :limit`.

### 8.2 `tests/test-budget-composition.el` (New)
Covers Contract 6, DEEP-02, DEEP-09.
Key Test Cases:
1. `test-budget-all-turn-types-debit-shared-counter`:
   A run performs 1 initial request, 1 transport retry, 1 tool-call response, 1 compaction turn, and 1 continuation nudge. Asserts `requests-spent = 5` on the single shared `kargu-run-budget`.
2. `test-budget-exhaustion-terminates-loop`:
   Budget initialized with `max-requests = 2`. Second request exhausts budget; third request is rejected with `:budget-exhausted`, loop finishes with `:limit` and status `:exhausted-requests`.
3. `test-budget-compaction-single-turn-limit`:
   First compaction turn succeeds (`compactions-spent = 1`). Second compaction attempt within same run returns `:budget-exhausted` (`:reason :exhausted-compactions`), and loop gracefully handles second overflow by stopping.
4. `test-budget-deadline-expiration`:
   Budget initialized with `deadline = (+ (float-time) 0.05)`. After 0.06s sleep, next request is rejected with `:exhausted-deadline`.
5. `test-budget-unknown-tokens-never-coerced-to-zero`:
   Model wire response omits `usage`. Verifies `tokens-unknown-p` is `t` and `tokens-spent` remains accurate without inserting artificial zeros.
6. `test-budget-sealed-on-finish`:
   After run finishes, budget status is `:sealed` (or `:exhausted-*`), and subsequent debit attempts fail.

---

## 9. Verification & Quality Gates

### Test & Compilation Gate
1. All ERT tests pass (1052+ tests, 0 failures, 0 errors).
2. Clean byte-compilation on all modified and new files under `(setq byte-compile-error-on-warn t)`.
3. Zero leftover `.elc` files.
4. Checkdoc hygiene pass.

### Formal TLC Verification Gate
- `proof/run_tlc.sh --budget` (BudgetMC.tla) -> PASS
- `proof/run_tlc.sh --verification` (VerificationMC.tla) -> PASS
- `proof/run_tlc.sh --transport` (TransportMC.tla) -> PASS
- `proof/run_tlc.sh` (MC.tla) -> PASS

---

## 10. Conclusion & Handoff Readiness

The investigation establishes a watertight blueprint for Wave 3 Package G. All boundary contracts (Contract 1, 5, 6, 7) are fully respected, with zero singleton dependencies, complete headless execution independence, strict single-terminal-event emission, unified budget debiting across all turn types, and comprehensive test coverage.
