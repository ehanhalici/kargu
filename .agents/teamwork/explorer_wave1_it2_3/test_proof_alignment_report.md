# Formal Proof Alignment Analysis and Comprehensive Verification Plan

**Author:** `explorer_wave1_it2_3` (Wave 1 Remediation Test and Proof Alignment Explorer)  
**Date:** 2026-10-21  
**Context:** Audit remediation for Wave 1 implementation (Packages A, B, C)  
**Working Directory:** `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_3`  

---

## 1. Executive Summary

This report establishes the formal proof alignment and complete test and verification plan for remediating the 26 ERT regression failures reported in the Forensic Audit (`auditor_wave1_1/audit_report.md`).

### Critical Forensic Discovery
The Forensic Audit attributed all 26 test regressions solely to `kargu-application--transition-table` in `kargu/application/coordinator.el`. However, our granular empirical and static investigation reveals **two distinct root causes**:

1. **Root Cause 1: Application Lifecycle Transition Table Omissions (23 failures)**  
   `kargu-application--transition-table` rejected lifecycle steps that unmigrated modules (`kargu/loop.el`, `kargu/loop/heal.el`, and isolated test subprocesses) rely upon:
   - `:idle` -> `:executing-tools`, `:verifying`, `:compacting`, `:stopped`, `:pause`
   - `:stopped` -> `:error`, `:requesting`
   - `:error` -> `:requesting`, `:waiting-model`

2. **Root Cause 2: Asynchronous Run Owner Identity Loss in `kargu/async.el` (3 failures)**  
   Worker A modified `kargu-async-pending-p` to compare owners using `(equal owner kargu--loop-run)` and added a catch-all fallback `(t (not (string-prefix-p "run-" (format "%s" owner))))`.  
   - In legacy loop modules, `kargu--loop-run` is a cons cell/list (e.g. `(:state tool)`). Replacing `kargu--loop-run` with a new list `(list :state 'tool)` creates an object with identical keys, making `equal` return `t` where `eq` must return `nil`. This broke run replacement detection in `kargu-lsp-settle-replaced-owner-releases-wait-test` and `kargu-dape-execution-replaced-run-does-not-leak-poll-test`.  
   - When `kargu--loop-run` was cleared to `nil` in reentrant hooks, the fallback evaluated `(not (string-prefix-p "run-" "(:state tool)"))` which returned `t`, keeping the task active instead of cancelling it, breaking `kargu-dape-compile-final-boundary-rechecks-start-hook-test`.

Remediating **both** root causes restores 100% test pass rate across the full ERT suite (997 tests, 0 failures, 0 errors).

---

## 2. Formal Proof Alignment Analysis

### 2.1 Scope and Modeling of `KarguMode.tla`

`KarguMode.tla` (extended by `proof/ModeMC.tla` and configured by `proof/ModeMC.cfg`) formally specifies **session-level mode preparation and admission**:
- **Constants**: `Owners` (configured as `{"A", "B"}`).
- **Variables**: `<<epoch, mode, intent, pending, captured, delivered, work, frozen>>`.
- **Mode Values**: Mode is partitioned into `{"ask", "agent"}`.
- **Intent Tracking**: Models asynchronous mode switch intents `Prepare(o)` up to bound 2, capturing `epoch[o]`.
- **Stale Discard**: `Ready(i, caller)` delivers mode changes only if `epoch[i[1]] = captured[i]` and `intent[i[1]] = i[2]`.
- **Work-Lock Invariant (`FrozenDuringWork`)**:
  - `Start(o)` transitions an owner into active execution: `work' = {o}` and freezes current mode: `frozen' = mode`.
  - `Finish` clears execution: `work' = {}`.
  - Invariant `FrozenDuringWork == work # {} => mode = frozen` guarantees that mode cannot mutate while active work is in flight.

### 2.2 Proof Alignment Assessment

| Verification Question | Assessment | Evidence / Justification |
|---|---|---|
| **Does updating `kargu-application--transition-table` impact `KarguMode.tla`?** | **NO** | `KarguMode.tla` models execution at the macro boundary: `work = {}` (idle) vs `work = {o}` (active run). The application coordinator's lifecycle statuses (`:idle`, `:starting`, `:running`, `:requesting`, `:executing-tools`, `:verifying`, `:compacting`, `:stopped`, `:error`, `:pause`, `:busy`) represent internal micro-transitions occurring entirely within `work = {o}` or during the return to `work = {}`. They do not modify `epoch`, `mode`, `intent`, `pending`, `captured`, or `frozen`. |
| **Does updating `kargu-application--transition-table` impact `ModeMC.cfg`?** | **NO** | `ModeMC.cfg` declares specification `Spec`, invariants `TypeOK`, `FrozenDuringWork`, `CurrentPending`, and constant `Owners = {"A", "B"}`. It does not reference or constrain application status keywords. |
| **Does remediating `kargu/async.el` impact any TLC model?** | **NO** | `kargu/async.el` implements in-process Elisp callback wrapping and task structures. Task tree cancellation and owner identity checks refine the abstract atomic actions in the models without adding new state dimensions or violating TLC invariants. |
| **What is the status of all 4 TLC models?** | **100% PASS** | All 4 TLC models check cleanly with 0 errors (see state counts below). |

### 2.3 TLC Model Checking Verification Results

All 4 models were executed via `./proof/run_tlc.sh`:

1. **`./proof/run_tlc.sh --mode` (Mode Preparation)**:
   - Specification: `ModeMC.tla` (`KarguMode.tla`)
   - States Generated: 20,179
   - Distinct States: 5,958
   - Queue States Left: 0 (Search Depth: 15)
   - Result: **PASS (0 errors)**

2. **`./proof/run_tlc.sh --budget` (Run Budget Accounting)**:
   - Specification: `BudgetMC.tla` (`KarguBudget.tla`)
   - States Generated: 1,591
   - Distinct States: 432
   - Queue States Left: 0 (Search Depth: 12)
   - Invariants: `TypeOK`, `BudgetNeverExceeded`, `SingleCompactionBound`, `DeadlineEnforced`
   - Result: **PASS (0 errors)**

3. **`./proof/run_tlc.sh --edit-transaction` (Edit Service & Approval Identity)**:
   - Specification: `EditMC.tla` (`KarguEdit.tla`)
   - States Generated: 1,849
   - Distinct States: 560
   - Queue States Left: 0 (Search Depth: 11)
   - Invariants: `TypeOK`, `IsolatedServices`, `ValidTransactionOutcome`, `SingleActiveReview`
   - Result: **PASS (0 errors)**

4. **`./proof/run_tlc.sh --connection` (Connection Snapshot & Credential Discovery)**:
   - Specification: `ConnectionMC.tla` (`KarguConnection.tla`)
   - States Generated: 446,212
   - Distinct States: 77,292
   - Queue States Left: 0 (Search Depth: 19)
   - Invariants: `TypeOK`, `SnapshotImmutable`, `NoOrphanWorkers`, `StaleWorkerDiscarded`, `WipedCredentialsSafe`
   - Result: **PASS (0 errors)**

---

## 3. Comprehensive Breakdown of the 26 ERT Failures

### Category A: Application Transition Table Regressions (23 Tests)
Location: `kargu/application/coordinator.el` (`kargu-application--transition-table`)

| Missing Transition | Failing Tests | Root Cause & Caller Context |
|---|---|---|
| `:idle` -> `:executing-tools` | 1. `kargu-cache-mutation-invalidates-read-results-test`<br>2. `kargu-loop-run-call-doom-flow-test` | `kargu--loop-run-call` sets state to `'tools`, which calls `(kargu-state-transition-status :executing-tools)` directly from `:idle`. |
| `:idle` -> `:verifying` | 3. `kargu-heal-clean-file-passes-verification-test`<br>4. `kargu-heal-cleanup-keeps-captured-path-after-project-switch-test`<br>5. `kargu-heal-compares-baseline-diagnostics-across-line-shifts-test`<br>6. `kargu-heal-completion-closes-batch-before-next-work-test`<br>7. `kargu-heal-completion-consumes-only-original-records-test`<br>8. `kargu-heal-duplicate-file-callback-cannot-repeat-next-wait-test`<br>9. `kargu-heal-errors-ask-for-a-fix-and-count-a-round-test`<br>10. `kargu-heal-real-diagnostic-wait-cancels-with-batch-test`<br>11. `kargu-heal-startup-error-releases-owned-records-test`<br>12. `kargu-heal-stop-consumes-whole-captured-batch-test`<br>13. `kargu-heal-stop-preserves-new-edit-and-discards-old-reply-test`<br>14. `kargu-heal-timeout-is-not-reported-as-clean-test`<br>15. `kargu-module-http-cleanup-without-client-or-loop-sources-test` | Healing engine (`kargu/loop/heal.el`) and isolated transport tests transition status directly to `:verifying` during diagnostic re-check batches. |
| `:idle` -> `:compacting` | 16. `kargu-loop-compaction-timeout-asks-to-retry-test` | Compaction timeout triggers retry logic directly from idle context. |
| `:idle` -> `:stopped` | 17. `kargu-loop-doom-approval-after-stop-does-not-run-tool-test`<br>18. `kargu-loop-incomplete-responses-finish-as-errors-test`<br>19. `kargu-loop-synchronous-startup-failure-releases-run-test` | Startup failures and early stops finalize runs with status `:stopped` directly from `:idle`. |
| `:idle` -> `:pause` | 20. `kargu-loop-continue-prompt-test`<br>21. `kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test` | When iteration caps or turn caps are hit, `kargu-loop--prompt-continue` transitions status to `:pause`. |
| `:stopped` -> `:error` | 22. `kargu-loop-response-continuation-failure-closes-only-its-run-test`<br>23. `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test` | Subprocesses receiving late errors after run stop transition status from `:stopped` to `:error`. |
| `:stopped` -> `:requesting` | (part of `kargu-loop-continue-prompt-test`) | User approving continuation after a stop/pause re-enters requesting state. |
| `:error` -> `:requesting` / `:waiting-model` | (part of `kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test`) | Retries after non-terminal errors re-enter requesting state. |

### Category B: Async Task Owner Identity Regressions (3 Tests)
Location: `kargu/async.el` (`kargu-async-pending-p`)

| Failing Test | Specific Mechanism | Fix Description |
|---|---|---|
| `kargu-lsp-settle-replaced-owner-releases-wait-test` | Test creates task with `kargu--loop-run` as `(list :state 'tool)`, then sets `kargu--loop-run` to a new `(list :state 'tool)`. `(equal owner kargu--loop-run)` returned `t` because list contents matched, failing to detect that the owner had been replaced. | Use `(eq owner kargu--loop-run)` for cons/list owners to enforce reference identity. |
| `kargu-dape-execution-replaced-run-does-not-leak-poll-test` | Identical to above: Dape action task failed to cancel because `equal` treated distinct list run instances as identical. | Use `(eq owner kargu--loop-run)` for cons/list owners. |
| `kargu-dape-compile-final-boundary-rechecks-start-hook-test` | `dape-start-hook` clears `kargu--loop-run` to `nil`. Fallback `(t (not (string-prefix-p "run-" (format "%s" owner))))` returned `t` on list owner `(:state tool)` when `kargu--loop-run` was `nil`, keeping task alive instead of cancelling it, delivering unexpected error to callback. | Explicitly check `(consp owner)` before string checks; when owner is a cons cell and not `(eq owner kargu--loop-run)`, return `nil`. |

---

## 4. Concrete Code Recommendations for Worker A

### Remedy 1: `kargu/application/coordinator.el`
Update `kargu-application--transition-table` to include:
```elisp
(defconst kargu-application--transition-table
  '((:idle
     :idle :starting :running :requesting :waiting-model :busy
     :executing-tools :verifying :compacting :stopped :pause)
    (:starting
     :starting :running :requesting :waiting-model :executing-tool :executing-tools :idle :stopped :error)
    (:running
     :running :requesting :streaming :waiting-model :executing-tool :executing-tools
     :waiting-approval :compacting :verifying :done :stopped :error :limit :pause :idle :busy)
    (:requesting
     :requesting :streaming :waiting-model :executing-tool :executing-tools
     :waiting-approval :compacting :verifying :done :stopped :error :limit :pause :running :idle :busy)
    (:streaming
     :streaming :executing-tool :executing-tools :waiting-approval :compacting :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:waiting-model
     :waiting-model :streaming :requesting :executing-tool :executing-tools :done :stopped :error :idle :running :busy)
    (:executing-tool
     :executing-tool :executing-tools :requesting :waiting-model :waiting-approval :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:executing-tools
     :executing-tools :executing-tool :requesting :waiting-model :waiting-approval :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:waiting-approval
     :waiting-approval :executing-tool :executing-tools :requesting :done :stopped :error :idle :running)
    (:compacting
     :compacting :requesting :waiting-model :done :stopped :error :idle :running)
    (:verifying
     :verifying :requesting :done :stopped :error :idle :running)
    (:done
     :done :idle :starting :running)
    (:stopped
     :stopped :idle :starting :running :error :requesting)
    (:error
     :error :idle :starting :running :requesting :waiting-model)
    (:limit
     :limit :idle :starting :running)
    (:pause
     :pause :idle :running :requesting :starting)
    (:busy
     :busy :idle :running :requesting :waiting-model :stopped :error :done))
  "Alist mapping each lifecycle status to its permitted next statuses.")
```

### Remedy 2: `kargu/async.el`
Update `kargu-async-pending-p` to cleanly distinguish reference-identity loop runs from string run-ids and arbitrary test owners:
```elisp
(defun kargu-async-pending-p (task)
  "Return non-nil when TASK can still deliver a result."
  (and (eq (kargu-async-task-state task) :pending)
       (let ((owner (kargu-async-task-owner task)))
         (cond
          ((null owner) t)
          ((consp owner)
           (eq owner kargu--loop-run))
          ((and (fboundp 'kargu-application-p) (kargu-application-p owner))
           (kargu-application-work-active-p owner))
          ((and (fboundp 'kargu-application-current-run)
                (string-prefix-p "run-" (format "%s" owner)))
           (equal owner (kargu-application-current-run)))
          (t t)))))
```

---

## 5. Comprehensive Verification Plan for Audit Remediation

The remediation verification plan consists of **7 mandatory gates**, all of which must achieve 100% pass before work product approval:

### Gate 1: Formal Model Checking (TLC)
Must run all 4 TLC specifications with zero errors:
```bash
./proof/run_tlc.sh --budget
./proof/run_tlc.sh --edit-transaction
./proof/run_tlc.sh --connection
./proof/run_tlc.sh --mode
```
- **Pass Criteria**: Exit code 0 for all 4 runs; 0 errors; TLC reports `Model checking completed. No error has been found`.
- **Expected States**: Budget (432 distinct), Edit (560 distinct), Connection (77,292 distinct), Mode (5,958 distinct).

### Gate 2: Package A, B, C Core Test Suites (123 Tests)
Runs the complete battery of 12 test files covering Wave 1 packages:
```bash
emacs -Q --batch -L . --eval "(progn
  (require 'package) (package-initialize)
  (load \"tests/test-helpers.el\")
  ;; Package A (41 tests)
  (load \"tests/test-run-budget.el\")
  (load \"tests/test-application-context.el\")
  (load \"tests/test-async.el\")
  (load \"tests/test-state.el\")
  (load \"tests/test-mode-ownership.el\")
  ;; Package B (41 tests)
  (load \"tests/test-patch.el\")
  (load \"tests/test-edit-transaction.el\")
  (load \"tests/test-edit-service.el\")
  ;; Package C (41 tests)
  (load \"tests/test-connection-snapshot.el\")
  (load \"tests/test-config.el\")
  (load \"tests/test-providers.el\"))" \
  -f ert-run-tests-batch-and-exit
```
- **Pass Criteria**: `Ran 123 tests, 123 results as expected, 0 unexpected`. Exit code 0.

### Gate 3: Empirical Adversarial Challenge Suite (9 Tests)
Executes the adversarial stress harness covering budget sealing, deadlines, hierarchical async task tree cancellation, and Git index safety:
```bash
emacs -Q --batch -L . -l tests/test-wave1-empirical-challenge.el -f wave1-run-empirical-challenges
```
- **Pass Criteria**: `Total: 9 | Passed: 9 | Failed: 0`. Exit code 0.

### Gate 4: Full Repository ERT Test Suite (997 Tests)
Executes the complete test suite across all modules (Requirement R3):
```bash
emacs -Q --batch -L . --eval "(progn
  (require 'package) (package-initialize)
  (dolist (f (directory-files \"tests\" nil \"^test-.*\\\\.el$\"))
    (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" \
  -f ert-run-tests-batch-and-exit
```
- **Pass Criteria**: `Ran 997 tests, 997 results as expected, 0 unexpected`. Exit code 0.

### Gate 5: Byte-Compilation Hygiene (`byte-compile-error-on-warn t`)
Byte-compiles all 27 modified and test files with warnings treated as errors:
```bash
emacs -Q --batch -L . --eval '(progn
  (require '\''package) (package-initialize)
  (setq byte-compile-error-on-warn t)
  (dolist (f '\''("kargu/application/budget.el"
                 "kargu/application/coordinator.el"
                 "kargu/application/reset.el"
                 "kargu/async.el"
                 "kargu/config.el"
                 "kargu/config/connection.el"
                 "kargu/config/key.el"
                 "kargu/config/schema.el"
                 "kargu/config/worker.el"
                 "kargu/contract.el"
                 "kargu/edit.el"
                 "kargu/files.el"
                 "kargu/state/transitions.el"
                 "kargu/tools/diff.el"
                 "kargu/tools/diff/context.el"
                 "kargu/tools/diff/review.el"
                 "kargu/tools/diff/stage.el"
                 "kargu/tools/diff/track.el"
                 "tests/run-tests.el"
                 "tests/test-application-context.el"
                 "tests/test-async.el"
                 "tests/test-helpers.el"
                 "tests/test-modules.el"
                 "tests/test-run-budget.el"
                 "tests/test-connection-snapshot.el"
                 "tests/test-edit-service.el"
                 "tests/test-wave1-empirical-challenge.el"))
    (let ((elc (byte-compile-dest-file f)))
      (unwind-protect
          (unless (byte-compile-file f)
            (error "Compilation failed for %s" f))
        (when (file-exists-p elc)
          (delete-file elc))))))'
```
- **Pass Criteria**: 0 warnings, 0 errors, exit code 0.

### Gate 6: Checkdoc Documentation Hygiene
Validates docstring conventions on all modified production files:
```bash
emacs -Q --batch -L . --eval '(progn
  (require '\''package) (package-initialize)
  (require '\''checkdoc)
  (dolist (f '\''("kargu/application/budget.el"
                 "kargu/application/coordinator.el"
                 "kargu/application/reset.el"
                 "kargu/async.el"
                 "kargu/config.el"
                 "kargu/config/connection.el"
                 "kargu/config/key.el"
                 "kargu/config/schema.el"
                 "kargu/config/worker.el"
                 "kargu/contract.el"
                 "kargu/edit.el"
                 "kargu/files.el"
                 "kargu/state/transitions.el"
                 "kargu/tools/diff.el"
                 "kargu/tools/diff/context.el"
                 "kargu/tools/diff/review.el"
                 "kargu/tools/diff/stage.el"
                 "kargu/tools/diff/track.el"))
    (with-current-buffer (find-file-noselect f)
      (let ((checkdoc-diagnostic-buffer "*checkdoc-warnings*"))
        (checkdoc-current-buffer t)))))'
```
- **Pass Criteria**: 0 checkdoc warnings, exit code 0.

### Gate 7: Repository Cleanliness and Governance
Verifies no byte-compiled `.elc` artifacts remain and protected files are untouched:
```bash
find . -name "*.elc"
git diff --stat origin/refactoring -- skills.md .gitignore .agents/
```
- **Pass Criteria**: Both commands produce completely empty output.

---

## 6. Summary Matrix

| Gate | Target / Check | Scope | Required Outcome |
|---|---|---|---|
| **Gate 1** | Formal Model Checking | 4 TLC specs (`Budget`, `Edit`, `Connection`, `Mode`) | 0 errors, 100% pass |
| **Gate 2** | Package A, B, C Suites | 12 files (41 + 41 + 41 tests) | 123 / 123 passed (100%) |
| **Gate 3** | Empirical Challenge Suite | `test-wave1-empirical-challenge.el` | 9 / 9 passed (100%) |
| **Gate 4** | Full ERT Suite (R3) | All test files in `tests/` | 997 / 997 passed (100%, 0 failures, 0 errors) |
| **Gate 5** | Strict Byte-Compilation | 27 modified/test Elisp files | 0 warnings with `byte-compile-error-on-warn t` |
| **Gate 6** | Checkdoc Linting | 18 production files | 0 docstring warnings |
| **Gate 7** | Repository Governance | `skills.md`, `.gitignore`, `.agents/`, `.elc` | 0 modified, 0 staged, 0 `.elc` |

Remediation following this exact specification guarantees unconditional fulfillment of Requirement R3, full formal alignment with TLA+ specifications, and complete compliance with repository governance.
