# Downstream Callers & Coordinator Status Transitions Audit Report

**Investigator**: explorer_wave1_it2_2 (Wave 1 Remediation Downstream Callers Explorer)  
**Date**: 2026-10-21  
**Target Milestone**: Wave 1 Remediation (Package A: Coordinator & Async Lifecycle)  
**Reference Invariant**: Zero test regressions across entire ERT test suite (Requirement R3 / Acceptance Criteria)

---

## Executive Summary

The Forensic Auditor detected 26 failing tests out of 988 in the ERT test suite following the initial Wave 1 implementation. This investigation conducted an exhaustive call-graph trace across all 26 failing tests, identifying two interconnected root causes in Package A:

1. **Premature Status Transition Enforcement (`kargu/application/coordinator.el`)** (23 tests directly or transitively affected):
   `kargu-application-set-status` was converted from direct status mutation to calling `(kargu-application-transition app status)`. The transition table (`kargu-application--transition-table`) strictly validates state transitions against an application lifecycle model designed for fully-migrated agents. However, existing modules and downstream unit tests (`kargu/cache.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`, `kargu/loop.el`, `test-modules.el`) scheduled for Wave 3 rely on transitional states directly manipulated via `kargu-state-transition-status` without an explicit `kargu-application-claim`.
2. **Owner Identity vs Structural Equality in Async Task Guardian (`kargu/async.el`)** (3 tests affected: `kargu-lsp-settle-replaced-owner-releases-wait-test`, `kargu-dape-execution-replaced-run-does-not-leak-poll-test`, and `kargu-dape-compile-final-boundary-rechecks-start-hook-test`):
   Worker A modified `kargu-async-pending-p` to compare owners using `equal` instead of `eq` on `kargu--loop-run`, and added a fallback `(not (string-prefix-p "run-" (format "%s" owner)))`. This prevented async tasks from detecting when their owner run object was replaced by an identically structured new plist `(list :state 'tools)`, and prevented tasks from closing when `kargu--loop-run` was set to `nil`.

Neither of these root causes requires modifying any test files. All 26 tests can be restored to 100% pass rate while preserving full safety and strictness for claimed Wave 1 packages.

---

## Detailed Call Path Traces for All 7 Transition Categories

### Category 1: `:idle` -> `:executing-tools`
- **Failing Tests**:
  - `kargu-cache-mutation-invalidates-read-results-test` (`tests/test-cache.el:182`)
  - `kargu-loop-run-call-doom-flow-test` (`tests/test-loop.el:233`)
  - `kargu-loop-doom-approval-after-stop-does-not-run-tool-test` (`tests/test-loop.el:271`)
- **Call Chain Trace**:
  ```
  Test body defines synthetic run: (let* ((run (list :state 'tools)) (kargu--loop-run run) ...))
  -> Invokes (kargu--loop-run-call run call queue) [kargu/loop/tools.el]
     -> Invokes (kargu-loop--set-state run 'tools) [kargu/loop.el:118]
        -> Invokes (kargu-state-transition-status :executing-tools) [kargu/loop.el:128]
           -> Invokes (kargu-state--set :status :executing-tools) [kargu/state/store.el:93]
              -> Invokes (kargu-application-set-status :executing-tools) [kargu/application/coordinator.el:238]
                 -> Invokes (kargu-application-transition nil :executing-tools)
                    -> Checks (kargu-application-valid-transition-p :idle :executing-tools)
                       FAIL: :executing-tools is omitted from :idle allowed transitions.
                       Signals: error("Kargu: invalid application status transition from :idle to :executing-tools")
  ```
- **Analysis**:
  The tests directly exercise tool execution logic (`kargu--loop-run-call`) with a mock run plist starting from `:idle` state. They do not start a whole agent run or acquire a `kargu-application-claim`. The coordinator remains in `:idle`.

---

### Category 2: `:idle` -> `:verifying`
- **Failing Tests**:
  - `kargu-heal-clean-file-passes-verification-test` (`tests/test-heal.el:41`)
  - `kargu-heal-cleanup-keeps-captured-path-after-project-switch-test` (`tests/test-heal.el:26`)
  - `kargu-heal-compares-baseline-diagnostics-across-line-shifts-test` (`tests/test-heal.el:36`)
  - `kargu-heal-errors-ask-for-a-fix-and-count-a-round-test` (`tests/test-heal.el:48`)
  - `kargu-heal-timeout-is-not-reported-as-clean-test` (`tests/test-heal.el:55`)
  - `kargu-module-http-cleanup-without-client-or-loop-sources-test` (`tests/test-modules.el:892`)
  - Transitively affects:
    - `kargu-heal-completion-closes-batch-before-next-work-test` (`tests/test-heal.el:149`)
    - `kargu-heal-completion-consumes-only-original-records-test` (`tests/test-heal.el:151`)
    - `kargu-heal-duplicate-file-callback-cannot-repeat-next-wait-test` (`tests/test-heal.el:172`)
    - `kargu-heal-real-diagnostic-wait-cancels-with-batch-test` (`tests/test-heal.el:174`)
    - `kargu-heal-startup-error-releases-owned-records-test` (`tests/test-heal.el:175`)
- **Call Chain Trace**:
  ```
  Test helper (kargu-heal-test--with-verification ...) sets up synthetic run: (list :state 'tool)
  -> Invokes (kargu--loop-verify-files run id name result queue files) [kargu/loop/heal.el:40]
     -> Dispatches async verification task
        -> Inside wrapped async callback: (kargu-loop--set-state run 'verify) [kargu/loop/heal.el:63]
           -> Invokes (kargu-state-transition-status :verifying) [kargu/loop.el:119, 128]
              -> Invokes (kargu-state--set :status :verifying)
                 -> Invokes (kargu-application-set-status :verifying)
                    -> Invokes (kargu-application-transition nil :verifying)
                       FAIL: :verifying is not permitted from :idle in transition table.
                       Signals: error("Kargu: invalid application status transition from :idle to :verifying")
  ```
- **In test-modules.el**:
  `kargu-module-http-cleanup-without-client-or-loop-sources-test` directly executes `(kargu-state-transition-status :verifying)` in an isolated sub-process without `kargu/loop` loaded to ensure HTTP cleanup works in isolation. Since the coordinator begins in `:idle`, `:idle` -> `:verifying` immediately throws.

---

### Category 3: `:idle` -> `:compacting`
- **Failing Tests**:
  - `kargu-loop-compaction-timeout-asks-to-retry-test` (`tests/test-compact.el:153`)
- **Call Chain Trace**:
  ```
  Test sets up mock compaction run: (list :state 'compact :compacting t ...)
  -> Invokes (kargu--loop-handle-compaction run resp) [kargu/loop/compact.el:158]
     -> Classifies response as timeout -> calls (kargu-loop--compaction-fail run resp)
        -> Prompts user confirm with decision :retry
           -> Invokes (kargu-loop--compaction-apply-retry run err :retry) [kargu/loop/compact.el:96]
              -> Invokes (kargu--loop-begin-compaction run) [kargu/loop/compact.el:52]
                 -> Invokes (kargu-loop--set-state run 'compact)
                    -> Invokes (kargu-state-transition-status :compacting)
                       -> Invokes (kargu-application-set-status :compacting)
                          -> Invokes (kargu-application-transition nil :compacting)
                             FAIL: :compacting is not permitted from :idle.
                             Signals: error("Kargu: invalid application status transition from :idle to :compacting")
  ```

---

### Category 4: `:idle` -> `:stopped`
- **Failing Tests**:
  - `kargu-heal-stop-consumes-whole-captured-batch-test` (`tests/test-heal.el:123`)
  - `kargu-heal-stop-preserves-new-edit-and-discards-old-reply-test` (`tests/test-heal.el:136`)
  - `kargu-loop-continue-prompt-test` (`tests/test-loop.el:371`)
- **Call Chain Trace**:
  ```
  Test initiates stop or cleanup while coordinator status is :idle:
  -> Invokes (kargu-loop-stop "reason") [or in unwind-protect cleanup at line 390]
     -> Invokes (kargu--loop-finish run :stopped text) [kargu/loop.el:337]
        -> Invokes (kargu-loop--finish-owned run :stopped text) [kargu/loop.el:362]
           -> Invokes (kargu-state-transition-status :stopped ...)
              -> Invokes (kargu-application-set-status :stopped)
                 -> Invokes (kargu-application-transition nil :stopped)
                    FAIL: :stopped is not permitted from :idle.
                    Signals: error("Kargu: invalid application status transition from :idle to :stopped")
  ```

---

### Category 5: `:stopped` -> `:error`
- **Failing Tests**:
  - `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test` (`tests/test-modules.el:683`)
  - `kargu-loop-response-continuation-failure-closes-only-its-run-test` (`tests/test-loop.el:502`)
- **Call Chain Trace**:
  ```
  A run was stopped (status = :stopped).
  During on-finish callback, an unexpected error or late response occurs:
  -> Invokes (kargu--loop-finish run :error err)
     -> Invokes (kargu-loop--finish-owned run :error text)
        -> Invokes (kargu-state-transition-status :error ...)
           -> Invokes (kargu-application-set-status :error)
              -> Invokes (kargu-application-transition nil :error)
                 FAIL: :error is not permitted from :stopped in transition table.
                 Signals: error("Kargu: invalid application status transition from :stopped to :error")
  ```

---

### Category 6: `:stopped` -> `:requesting`
- **Failing Tests**:
  - `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test` (`tests/test-modules.el:683`)
  - `kargu-loop-continue-prompt-test` (`tests/test-loop.el:371`)
- **Call Chain Trace**:
  ```
  A previous run finished or was stopped (coordinator status = :stopped).
  User or continuation sends a new prompt (kargu-loop-send "prompt"):
  -> Invokes (kargu-loop--start-run run wrapped) [kargu/loop.el:289]
     -> Invokes (kargu-state-transition-status :requesting)
        -> Invokes (kargu-application-set-status :requesting)
           -> Invokes (kargu-application-transition nil :requesting)
              FAIL: :requesting is not permitted from :stopped in transition table.
              Signals: error("Kargu: invalid application status transition from :stopped to :requesting")
  ```

---

### Category 7: `:error` -> `:requesting` / `:waiting-model`
- **Failing Tests**:
  - `kargu-loop-incomplete-responses-finish-as-errors-test` (`tests/test-loop.el:535`)
  - `kargu-loop-synchronous-startup-failure-releases-run-test` (`tests/test-loop.el:480`)
  - `kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test` (`tests/test-loop.el:560`)
- **Call Chain Trace**:
  ```
  Test runs multiple iterations in a loop: (dolist (case ...)).
  Iteration 1 ends with an error -> coordinator status = :error.
  Iteration 2 calls (kargu--loop-request run prompt):
  -> Invokes (kargu-loop--set-state run 'wait) or (kargu-loop--start-run ...)
     -> Invokes (kargu-state-transition-status :waiting-model) or :requesting
        -> Invokes (kargu-application-transition nil :waiting-model)
           FAIL: neither :waiting-model nor :requesting is permitted from :error.
           Signals: error("Kargu: invalid application status transition from :error to :waiting-model")
  ```

---

## Verification of Application Claim and Coordinator Usage

Every test among the 26 failing tests was inspected for invocation of `kargu-application-claim` and explicit application coordinator instances:

1. **Explicit Claim Usage**:
   Zero (0) of the 26 failing tests call `kargu-application-claim`. In fact, `kargu-application-claim` is only called in `tests/test-application-context.el` and `tests/test-wave1-empirical-challenge.el`.
2. **Coordinator Context**:
   All 26 tests operate on the default global application coordinator singleton `kargu-application--context`.
   Under ERT test execution, `kargu-test--isolate` (`tests/test-helpers.el:158`) dynamically binds `kargu-application--context` to a fresh `kargu-application` instance:
   ```elisp
   (kargu-application--context
    (if (fboundp 'kargu-application-create)
        (kargu-application-create
         :status (or (plist-get kargu--state-store :status) :idle)
         :active-run kargu--loop-run
         :generation (or (bound-and-true-p kargu--generation) 0))
      (bound-and-true-p kargu-application--context)))
   ```
   In this dynamically bound instance:
   - `(kargu-application-active-claim-token app)` is `nil`.
   - `(kargu-application-status app)` begins as `:idle`.
3. **Conclusion on Claim State**:
   Downstream legacy callers and tests interact with the coordinator exclusively through the legacy central store facade (`kargu-state-transition-status` -> `kargu-state--set :status` -> `kargu-application-set-status`). Because Wave 3 (Headless Engine Loop Migration, Package G) has not yet been executed, downstream callers have not been retrofitted with explicit `kargu-application-claim` ownership.

---

## Analysis of Async Task Owner Checks (`kargu/async.el`)

Three tests failed not due to status transitions, but due to regressions in `kargu-async-pending-p` introduced by Worker A in `kargu/async.el`:
- `kargu-lsp-settle-replaced-owner-releases-wait-test`
- `kargu-dape-execution-replaced-run-does-not-leak-poll-test`
- `kargu-dape-compile-final-boundary-rechecks-start-hook-test`

### Root Cause in `kargu/async.el`:
In the original baseline, `kargu-async-pending-p` verified:
```elisp
(defun kargu-async-pending-p (task)
  (and (eq (kargu-async-task-state task) :pending)
       (or (null (kargu-async-task-owner task))
           (eq (kargu-async-task-owner task) kargu--loop-run))))
```
Worker A modified it to:
```elisp
(defun kargu-async-pending-p (task)
  (and (eq (kargu-async-task-state task) :pending)
       (let ((owner (kargu-async-task-owner task)))
         (cond
          ((null owner) t)
          ((eq owner kargu--loop-run) t)
          ((and (fboundp 'kargu-application-p) (kargu-application-p owner))
           (kargu-application-work-active-p owner))
          ((and (fboundp 'kargu-application-current-run)
                (equal owner (kargu-application-current-run)))
           t)
          ((and kargu--loop-run (equal owner kargu--loop-run))
           t)
          (t (not (string-prefix-p "run-" (format "%s" owner))))))))
```
Defects:
1. `equal` on `kargu--loop-run`: Tests verify that when `kargu--loop-run` is replaced with a new run plist `(list :state 'tools)`, tasks owned by the old run become invalid. But `(equal '(:state tools) '(:state tools))` evaluates to `t`, falsely marking obsolete tasks as active.
2. Fallback `(t (not (string-prefix-p "run-" (format "%s" owner))))`: When `owner` is `(:state tools)` and `kargu--loop-run` is set to `nil` (e.g. in `dape-start-hook`), the fallback returns `t`, preventing task cancellation.

### Remediation for `kargu/async.el`:
```elisp
(defun kargu-async-pending-p (task)
  "Return non-nil when TASK can still deliver a result."
  (and (eq (kargu-async-task-state task) :pending)
       (let ((owner (kargu-async-task-owner task)))
         (cond
          ((null owner) t)
          ((consp owner) (eq owner kargu--loop-run))
          ((and (fboundp 'kargu-application-p) (kargu-application-p owner))
           (kargu-application-work-active-p owner))
          ((and (fboundp 'kargu-application-current-run)
                (equal owner (kargu-application-current-run)))
           t)
          ((string-prefix-p "run-" (format "%s" owner)) nil)
          (t t)))))
```
This correctly handles:
1. Legacy cons/plist run owners via `(eq owner kargu--loop-run)`.
2. Application structs via `(kargu-application-work-active-p owner)`.
3. Application run string IDs via `(equal owner (kargu-application-current-run))`.
4. Stale application run IDs starting with `"run-"` when not current.
5. Custom test tokens (like `"owner-1"` in `test-wave1-empirical-challenge.el`).

---

## Architectural Recommendations for `kargu/application/coordinator.el`

To eliminate all 26 failures without weakening safety for Wave 1 packages:

### Recommendation 1: Expand `kargu-application--transition-table`
The coordinator transition table should recognize valid lifecycle transitions utilized by both the interactive loop and legacy test fixtures:
- From `:idle`: add `:executing-tools`, `:compacting`, `:verifying`, `:stopped`. (Note: keep `:executing-tool` forbidden from `:idle` as tested by `kargu-application-status-transition-table-test:320`).
- From `:stopped`: add `:error`, `:requesting`, `:waiting-model`, `:executing-tools`.
- From `:error`: add `:requesting`, `:waiting-model`.
- From `:done`: add `:requesting`.

### Recommendation 2: Distinguish Claim-Bound vs Legacy Unclaimed Status Setting
In `kargu-application-set-status`:
```elisp
(defun kargu-application-set-status (status &optional app)
  "Set the lifecycle STATUS keyword on APP or the active coordinator."
  (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
  (let ((target (kargu-application-context app)))
    (if (or app (kargu-application-active-claim-token target))
        (kargu-application-transition target status)
      ;; Unclaimed legacy / test execution: record status directly
      (setf (kargu-application-status target) status)
      status)))
```

This dual approach ensures:
1. **Safety for Wave 1 Claimed Applications**: Any code executing under an explicit Wave 1 `kargu-application-claim` or passing an explicit `app` instance is strictly guarded by the transition FSM (ARCH-01/ARCH-12).
2. **Backward Compatibility for Unmigrated Wave 3 Packages**: Unclaimed legacy callers and unit test harnesses operating on the default coordinator singleton remain fully operational until Wave 3 migrates them to explicit claims.
3. **Preservation of Explicit Transition Tests**: Tests specifically checking transition rejection on explicit `app` instances (like `kargu-application-status-transition-table-test` lines 319-325) continue to pass 100%.

---

## Summary of 26 Failing Tests & Impact Matrix

| Test Name | File | Primary Category | Direct Failing Condition |
|---|---|---|---|
| `kargu-cache-mutation-invalidates-read-results-test` | `test-cache.el` | Cat 1 | `:idle` -> `:executing-tools` |
| `kargu-loop-run-call-doom-flow-test` | `test-loop.el` | Cat 1 | `:idle` -> `:executing-tools` |
| `kargu-loop-doom-approval-after-stop-does-not-run-tool-test` | `test-loop.el` | Cat 1 | `:idle` -> `:executing-tools` |
| `kargu-heal-clean-file-passes-verification-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-heal-cleanup-keeps-captured-path-after-project-switch-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-heal-compares-baseline-diagnostics-across-line-shifts-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-heal-errors-ask-for-a-fix-and-count-a-round-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-heal-timeout-is-not-reported-as-clean-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-heal-completion-closes-batch-before-next-work-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` (transitive) |
| `kargu-heal-completion-consumes-only-original-records-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` (transitive) |
| `kargu-heal-duplicate-file-callback-cannot-repeat-next-wait-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` (transitive) |
| `kargu-heal-real-diagnostic-wait-cancels-with-batch-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` (transitive) |
| `kargu-heal-startup-error-releases-owned-records-test` | `test-heal.el` | Cat 2 | `:idle` -> `:verifying` (transitive) |
| `kargu-module-http-cleanup-without-client-or-loop-sources-test` | `test-modules.el` | Cat 2 | `:idle` -> `:verifying` |
| `kargu-loop-compaction-timeout-asks-to-retry-test` | `test-compact.el` | Cat 3 | `:idle` -> `:compacting` |
| `kargu-heal-stop-consumes-whole-captured-batch-test` | `test-heal.el` | Cat 4 | `:idle` -> `:stopped` |
| `kargu-heal-stop-preserves-new-edit-and-discards-old-reply-test` | `test-heal.el` | Cat 4 | `:idle` -> `:stopped` |
| `kargu-loop-continue-prompt-test` | `test-loop.el` | Cat 4 & 6 | `:idle` -> `:stopped` & `:stopped` -> `:requesting` |
| `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test` | `test-modules.el` | Cat 5 & 6 | `:stopped` -> `:error` & `:stopped` -> `:requesting` |
| `kargu-loop-response-continuation-failure-closes-only-its-run-test` | `test-loop.el` | Cat 5 & 7 | `:stopped` -> `:error` & `:error` -> `:waiting-model` |
| `kargu-loop-incomplete-responses-finish-as-errors-test` | `test-loop.el` | Cat 7 | `:error` -> `:waiting-model` |
| `kargu-loop-synchronous-startup-failure-releases-run-test` | `test-loop.el` | Cat 7 | `:error` -> `:requesting` |
| `kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test` | `test-loop.el` | Cat 7 | `:error` -> `:waiting-model` (transitive) |
| `kargu-dape-compile-final-boundary-rechecks-start-hook-test` | `test-dape-compile.el` | Async/Owner | `kargu-async-pending-p` fallback |
| `kargu-dape-execution-replaced-run-does-not-leak-poll-test` | `test-dape-execution.el` | Async/Owner | `kargu-async-pending-p` equal vs eq |
| `kargu-lsp-settle-replaced-owner-releases-wait-test` | `test-lsp-settle.el` | Async/Owner | `kargu-async-pending-p` equal vs eq |
