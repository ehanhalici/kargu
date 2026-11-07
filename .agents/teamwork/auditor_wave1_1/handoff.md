# Handoff Report: Wave 1 Forensic Audit

**Auditor**: `auditor_wave1_1`
**Role**: Forensic Auditor
**Target**: Wave 1 Packages A, B, and C
**Verdict**: **INTEGRITY VIOLATION** (Rejected due to 26 ERT test suite failures)

---

## 1. Observation

1. **Governance & Tree Invariants**:
   - `git diff --stat origin/refactoring -- skills.md .gitignore .agents/` showed 0 changes.
   - `git status --porcelain skills.md .gitignore` showed empty (completely untouched and unstaged).
   - `.agents/rules/architecture_principles.md` is unstaged and has timestamp Oct 19 20:00.
   - `find . -name "*.elc"` returned 0 results.

2. **Code & Contract Implementation**:
   - `kargu/application/budget.el`: Genuine arithmetic, deadline checks, monotonic token accounting with `tokens-unknown-p`, and single-compaction tracking.
   - `kargu/tools/diff/context.el`: Disjoint hashtables for snapshots, changes, reviews, active plans; verified re-checks for document revision, dirty buffers, policy revision, and session identity before executing plans.
   - `kargu/config/worker.el`: Genuine non-blocking batch subprocess invocation; `argv` contains `("-Q" "--batch" "--eval" ... "--" host sources-str)` with no secrets passed in command-line arguments. Secret tokens are delivered through stdout pipe.
   - No dummy facades or hardcoded return values were observed.

3. **Byte-Compilation**:
   - All 26 modified/new files compiled cleanly with `(setq byte-compile-error-on-warn t)`:
     `emacs -Q --batch -L . ...` returned exit code 0 with 0 warnings.
   - No `.elc` files were retained in the repository tree.

4. **Formal Verification (TLA+/TLC)**:
   - `proof/run_tlc.sh --budget` (BudgetMC.tla): Passed (432 distinct states, 0 errors).
   - `proof/run_tlc.sh --connection` (ConnectionMC.tla): Passed (77,292 distinct states, 0 errors).
   - `proof/run_tlc.sh --edit-transaction` (EditMC.tla): Passed (560 distinct states, 0 errors).

5. **Empirical Challenges**:
   - `tests/test-wave1-empirical-challenge.el`: 9 out of 9 challenge tests passed cleanly under `(wave1-run-empirical-challenges)`.

6. **Full ERT Test Suite**:
   - Command:
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Result:
     `Ran 988 tests, 962 results as expected, 26 unexpected` (exited with code 1).
   - All 26 failed tests failed with:
     `error("Kargu: invalid application status transition from %S to %S" ...)`
   - Backtraces show `kargu-state-transition-status` calling `kargu-application-set-status`, which in `kargu/application/coordinator.el` calls `kargu-application-transition`.
   - The strict transition table (`kargu-application--transition-table`) rejects transitions required by unmigrated modules:
     - `:idle` -> `:executing-tools`, `:verifying`, `:compacting`, `:stopped`
     - `:stopped` -> `:error`, `:requesting`
     - `:error` -> `:requesting`, `:waiting-model`

---

## 2. Logic Chain

1. `ORIGINAL_REQUEST.md` establishes the ground truth constraints:
   - Requirement R3: "Maintain 100% passing rate across the entire ERT test suite (929+ tests)."
   - Acceptance Criteria: "All ERT test suites pass with 0 failures and 0 errors".
2. Running the verbatim acceptance test command executed 988 tests and produced 26 failures.
3. Analysis of the backtraces reveals that Worker A introduced `kargu-application-transition` inside `kargu-application-set-status`, replacing the direct status assignment.
4. Legacy modules (`kargu/loop.el`, `kargu/loop/heal.el`, scheduled for migration in Wave 3) still call `kargu-state-transition-status` directly from statuses like `:idle`, `:stopped`, and `:error`.
5. Because `kargu-application--transition-table` does not permit these transitional paths, calling `kargu-state-transition-status` raises unhandled errors, causing 26 regression failures.
6. The Forensic Auditor's protocol stipulates: "Block on failure: If ANY check fails, the verdict is INTEGRITY VIOLATION and the work product must be rejected."
7. Therefore, the work product must be rejected with the verdict **INTEGRITY VIOLATION**.

---

## 3. Caveats

- The failure is NOT an intentional fraud, facade, or hardcoded evasion; the implementations of Packages A, B, and C are genuine and high-quality.
- The failure is an architectural regression caused by premature enforcement of the new lifecycle transition table onto unmigrated legacy modules that still expect permissive state transitions.
- Fixing this requires updating `kargu-application--transition-table` in `kargu/application/coordinator.el` or scoping transition validation to owned application runs rather than global legacy state calls.

---

## 4. Conclusion

- **Verdict**: **INTEGRITY VIOLATION**
- **Action Required**: Reject work product. Task Worker A (or Coordinator) to resolve the 26 test regressions in `kargu/application/coordinator.el`. Once `kargu-application--transition-table` accommodates legacy transitions (or scopes validation to owned runs), the full test suite will pass and Wave 1 can be certified clean.

---

## 5. Verification Method

To verify this finding independently:
```bash
# 1. Run full ERT test suite:
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
# Observe: 26 unexpected failures out of 988 tests, all due to "Kargu: invalid application status transition from %S to %S".

# 2. Inspect coordinator transition table:
view_file kargu/application/coordinator.el lines 137-195
```
