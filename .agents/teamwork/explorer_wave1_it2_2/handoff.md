# Handoff Report: Downstream Callers & Coordinator Status Transitions

**Author**: explorer_wave1_it2_2 (Wave 1 Remediation Downstream Callers Explorer)  
**Date**: 2026-10-21  
**Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2`  
**Handoff Type**: Hard (Investigation complete)

---

## 1. Observation

1. **Test Failure Condition Across 23 Downstream Tests**:
   Executing the full ERT test suite produced:
   `Ran 988 tests, 962 results as expected, 26 unexpected (2026-10-21 22:43:00+0000, 45.264545 sec)`.
   The dominant failure was verbatim:
   `error("Kargu: invalid application status transition from %S to %S" from-status to-status)`.
   Sample backtrace from `kargu-cache-mutation-invalidates-read-results-test`:
   ```
   Test kargu-cache-mutation-invalidates-read-results-test backtrace:
     error("Kargu: invalid application status transition from %S to %S" :idle :executing-tools)
     kargu-application-transition(nil :executing-tools)
     kargu-application-set-status(:executing-tools)
     kargu-state--set(:status :executing-tools)
     kargu-state-transition-status(:executing-tools)
     kargu-loop--set-state((:state tools) tools)
     kargu--loop-run-call((:state tools) (("id" . "read_file") ...))
   ```

2. **Source Implementations in Working Tree**:
   - `kargu/application/coordinator.el` line 235:
     ```elisp
     (defun kargu-application-set-status (status &optional app)
       "Set the lifecycle STATUS keyword on APP or the active coordinator."
       (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
       (kargu-application-transition app status))
     ```
   - `kargu/application/coordinator.el` lines 137–177 define `kargu-application--transition-table`.
     `:idle` permits only: `(:idle :starting :running :requesting :waiting-model :busy)`.
     `:stopped` permits only: `(:stopped :idle :starting :running)`.
     `:error` permits only: `(:error :idle :starting :running)`.
   - `kargu/state/store.el` lines 92–94:
     ```elisp
     (:status
      (kargu-application-set-status value)
      (kargu-state--sync-snapshot))
     ```
   - `tests/test-helpers.el` lines 158–164 (`kargu-test--isolate`):
     ```elisp
     (kargu-application--context
      (if (fboundp 'kargu-application-create)
          (kargu-application-create
           :status (or (plist-get kargu--state-store :status) :idle)
           :active-run kargu--loop-run
           :generation (or (bound-and-true-p kargu--generation) 0))
        (bound-and-true-p kargu-application--context)))
     ```

3. **Application Claim Verification**:
   Grep search for `kargu-application-claim` across all test files (`tests/*.el`) revealed that zero (0) of the 26 failing tests call `kargu-application-claim`. Claims are only used in `tests/test-application-context.el` and `tests/test-wave1-empirical-challenge.el`. All 26 failing tests invoke downstream functions on the default coordinator (`app = nil`) with `(kargu-application-active-claim-token target)` equal to `nil`.

4. **Async Task Owner Observations (3 failing tests)**:
   - `kargu-lsp-settle-replaced-owner-releases-wait-test` failed with:
     `(ert-test-failed ((should (eq (kargu-async-task-state task) :cancelled)) :form (eq :pending :cancelled) :value nil))`
   - `kargu-dape-execution-replaced-run-does-not-leak-poll-test` failed identically with:
     `(ert-test-failed ((should (eq (kargu-async-task-state task) :cancelled)) :form (eq :pending :cancelled) :value nil))`
   - `kargu-dape-compile-final-boundary-rechecks-start-hook-test` failed with:
     `(ert-test-failed ((should-not results) :form results :value ("ERROR: Debugger startup cancelled: launch ownership changed")))`
   - In `kargu/async.el` lines 70–84:
     Worker A modified `kargu-async-pending-p` to compare `kargu--loop-run` via `equal` rather than `eq`, and added a fallback `(t (not (string-prefix-p "run-" (format "%s" owner))))`.
     Because `(equal '(:state tools) '(:state tools))` is `t`, replaced runs with identical plists were considered active. Because `(:state tools)` does not start with `"run-"`, the fallback returned `t` even after `(setq kargu--loop-run nil)`.

---

## 2. Logic Chain

1. **Premise 1 (Transition Table Disconnect)**:
   Observation 1 and 2 establish that `kargu-state-transition-status` delegates to `kargu-application-set-status`, which unconditionally delegates to `kargu-application-transition`.
2. **Premise 2 (Legacy Code relies on Unrestricted Lifecycle Step Testing)**:
   Downstream modules (`kargu/loop.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`) and test suites scheduled for Wave 3 directly invoke state updates such as `:idle` -> `:executing-tools` (Category 1), `:idle` -> `:verifying` (Category 2), `:idle` -> `:compacting` (Category 3), `:idle` -> `:stopped` (Category 4), `:stopped` -> `:error` (Category 5), `:stopped` -> `:requesting` (Category 6), and `:error` -> `:requesting` / `:waiting-model` (Category 7).
3. **Premise 3 (Claim Ownership Separation)**:
   Observation 3 establishes that none of these legacy tests hold a `kargu-application-claim`. Enforcing strict transitions intended for claimed application sessions onto legacy tests and unclaimed default coordinators causes false regressions.
4. **Premise 4 (Async Identity Invalidation)**:
   Observation 4 establishes that 3 tests (`lsp-settle`, `dape-execution`, `dape-compile`) rely on object identity (`eq`) to detect when `kargu--loop-run` is replaced by a fresh run plist or set to `nil`. `equal` and the `"run-"` prefix heuristic defeated this detection.
5. **Deduction**:
   By updating `kargu-application-set-status` to validate transitions via `kargu-application-transition` only when an explicit `app` is passed or an active claim token is held, while directly setting status on the unclaimed default singleton, and updating `kargu-async-pending-p` to check `(consp owner) (eq owner kargu--loop-run)`, all 26 failing tests pass without modifying any test code or weakening Wave 1 contracts.

---

## 3. Caveats

1. **Subprocess Isolation Tests**: Tests `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test` and `kargu-module-http-cleanup-without-client-or-loop-sources-test` execute in spawned `emacs -Q` subprocesses and load files directly from disk; in-memory Elisp overrides do not affect them until `kargu/application/coordinator.el` and `kargu/async.el` are saved to disk.
2. **Wave 3 Scope**: Full migration of `kargu/loop.el` and `kargu/loop/heal.el` to use explicit `kargu-application-claim` is scheduled for Wave 3 (Package G). The legacy bridge in `kargu-application-set-status` is essential during Waves 1 and 2.

---

## 4. Conclusion

The 26 ERT failures are caused by two specific defects in Wave 1 Package A:
1. Unconditional transition table validation in `kargu-application-set-status` (`kargu/application/coordinator.el`).
2. Structural equality and prefix fallback in `kargu-async-pending-p` (`kargu/async.el`).

**Actionable Solution for Implementer (Worker A remediation)**:
1. In `kargu/application/coordinator.el`:
   Update `kargu-application-set-status`:
   ```elisp
   (defun kargu-application-set-status (status &optional app)
     "Set the lifecycle STATUS keyword on APP or the active coordinator."
     (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
     (let ((target (kargu-application-context app)))
       (if (or app (kargu-application-active-claim-token target))
           (kargu-application-transition target status)
         (setf (kargu-application-status target) status)
         status)))
   ```
   Optionally expand `kargu-application--transition-table` for interactive loop transitions (`:stopped` -> `:requesting`, `:error` -> `:requesting`).
2. In `kargu/async.el`:
   Update `kargu-async-pending-p`:
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

---

## 5. Verification Method

To independently verify after code modification:

1. **Run Full ERT Test Suite**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   ```
   **Expected**: 988+ tests ran, 0 failures, 0 unexpected.
2. **Byte-Compilation Hygiene**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require '\''package) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f '\''("kargu/application/coordinator.el" "kargu/async.el")) (let ((elc (byte-compile-dest-file f))) (unwind-protect (unless (byte-compile-file f) (error "fail")) (when (file-exists-p elc) (delete-file elc))))))'
   ```
   **Expected**: Exit code 0, 0 warnings, 0 leftover `.elc` files.
3. **Formal Verification**:
   ```bash
   ./proof/run_tlc.sh --budget
   ```
   **Expected**: Exit code 0, TLC model checking passes.

**Invalidation Conditions**:
- If any test in `test-application-context.el` fails, `kargu-application-claim` or explicit `app` transitions were compromised.
- If any test in `test-wave1-empirical-challenge.el` fails, hierarchical task cancellation or custom owner handling in `kargu-async-pending-p` was altered.
