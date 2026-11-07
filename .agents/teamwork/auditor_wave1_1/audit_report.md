## Forensic Audit Report

**Work Product**: Wave 1 Implementation (Packages A, B, and C)
**Profile**: General Project
**Integrity Mode**: Development (from `ORIGINAL_REQUEST.md`)
**Verdict**: INTEGRITY VIOLATION

---

### Executive Summary

The Forensic Auditor conducted a comprehensive static and dynamic integrity audit of all work products delivered for Wave 1 (Package A: Application Coordinator, Reset, Budget, and Async; Package B: Owned Edit Service, Diff Context, and Transaction Identity; Package C: Background Credential Worker, Connection Snapshot, and Config Precedence).

The implementations of the new core components demonstrate high technical quality, genuine business logic, and rigorous mathematical specifications:
- `kargu/application/budget.el` contains genuine arithmetic, deadline calculations, and single-compaction tracking.
- `kargu/tools/diff/context.el` genuinely isolates change, snapshot, and review tables per service, with real validation against document revisions, policy revisions, and session identity.
- `kargu/config/worker.el` executes genuine non-blocking batch subprocesses, never exposes secret credentials in `argv`, and handles timeouts and cancellations cleanly.
- Formal TLA+ models (`BudgetMC.tla`, `EditMC.tla`, `ConnectionMC.tla`) all passed exhaustive TLC model checking with zero errors.
- Byte-compilation with `(setq byte-compile-error-on-warn t)` succeeded across all 26 modified/new files with zero warnings and zero leftover `.elc` files.
- Governance invariants held: `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` remained untouched and unstaged.

**HOWEVER, a critical verification failure was detected in Phase 2 Behavioral Verification:**
The full ERT test suite run failed with **26 unexpected failures** (962 passed, 26 failed out of 988 tests).
The failures were caused by Worker A's introduction of `kargu-application-transition` inside `kargu-application-set-status` (`kargu/application/coordinator.el`). The transition table (`kargu-application--transition-table`) strictly rejects transitions that unmigrated modules (`kargu/loop.el`, `kargu/loop/heal.el`, and associated tests scheduled for Wave 3) rely upon (e.g. `:idle` -> `:executing-tools`, `:idle` -> `:verifying`, `:idle` -> `:compacting`, `:stopped` -> `:error`, `:error` -> `:requesting`).

Because `ORIGINAL_REQUEST.md` Requirement R3 and Acceptance Criteria explicitly mandate:
> "Maintain 100% passing rate across the entire ERT test suite (929+ tests)"
> "All ERT test suites pass with 0 failures and 0 errors"

And because the Forensic Auditor operates under strict "Block on failure: If ANY check fails, the verdict is INTEGRITY VIOLATION and the work product must be rejected" rules, the verdict is **INTEGRITY VIOLATION**.

---

### Phase Results

| Phase / Check | Result | Details |
|---|---|---|
| **Phase 1: Repository Governance** | **PASS** | `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` are 100% untouched and unstaged. Zero `.elc` files exist in the repository tree. |
| **Phase 1: Facade & Stub Detection** | **PASS** | No dummy facades, no placeholder stubs, no fake return values matching test inputs. Implementations contain full real logic. |
| **Phase 1: Test Assertion Integrity** | **PASS** | No weakened assertions, no skipped tests, no mock bypasses that circumvent real validation. |
| **Phase 1: Secret Leakage (CONFIG-01, DEEP-14)** | **PASS** | Verified in `kargu/config/worker.el`: subprocess args are `("-Q" "--batch" "--eval" ... "--" host sources-str)`. Secrets are read via stdout pipe and never passed in command-line arguments. |
| **Phase 1: Budget Accounting (ARCH-01, DEEP-09)** | **PASS** | Verified in `kargu/application/budget.el`: genuine request counting, monotonic token accumulation, unknown token preservation, deadline checking, and single compaction bound. |
| **Phase 1: Edit Service Isolation (ARCH-03, ARCH-04)** | **PASS** | Verified in `kargu/tools/diff/context.el`: disjoint hash tables for snapshots, changes, and reviews; re-checks disk revision, dirty buffer, policy revision, and session identity before executing. |
| **Phase 2: Byte-Compilation Hygiene** | **PASS** | Byte-compiled 26 files with `(setq byte-compile-error-on-warn t)`. 0 warnings, 0 errors, 0 leftover `.elc` files. |
| **Phase 2: Formal Model Checking (TLC)** | **PASS** | Exhaustive model checking passed without errors: `BudgetMC.tla` (432 states), `EditMC.tla` (560 states), `ConnectionMC.tla` (77,292 states). |
| **Phase 2: Empirical Challenge Suite** | **PASS** | `wave1-run-empirical-challenges` passed 9 out of 9 tests cleanly. |
| **Phase 2: Full ERT Test Suite (R3)** | **FAIL** | 26 unexpected test failures out of 988 tests due to `kargu-application-transition` premature rejection of legacy lifecycle transitions. |

---

### Detailed Findings

#### Finding 1: ERT Test Suite Regressions via `kargu-application-transition` (CRITICAL)

- **Affected File**: `kargu/application/coordinator.el` (lines 137–195, 235–239)
- **Direct Cause**:
  `kargu-application-set-status` was rewritten from directly updating the status slot to calling `(kargu-application-transition app status)`.
  `kargu/state/store.el` delegates `kargu-state--set :status` directly to `kargu-application-set-status`.
  Existing legacy modules (`kargu/loop.el`, `kargu/loop/heal.el`, and related ERT tests) invoke `kargu-state-transition-status` with lifecycle steps that are valid in the legacy state machine but omitted from `kargu-application--transition-table`:
  1. `:idle` -> `:executing-tools` (breaks `kargu-cache-mutation-invalidates-read-results-test`, `kargu-loop-run-call-doom-flow-test`)
  2. `:idle` -> `:verifying` (breaks `kargu-heal-clean-file-passes-verification-test`, `kargu-heal-compares-baseline-diagnostics-across-line-shifts-test`, etc.)
  3. `:idle` -> `:compacting` (breaks `kargu-loop-compaction-timeout-asks-to-retry-test`)
  4. `:idle` -> `:stopped` (breaks `kargu-module-closing-run-owner-cancels-and-rejects-reentry-test`)
  5. `:stopped` -> `:error` (breaks `kargu-loop-response-continuation-failure-closes-only-its-run-test`)
  6. `:stopped` -> `:requesting` (breaks `kargu-loop-continue-prompt-test`)
  7. `:error` -> `:requesting` / `:waiting-model` (breaks `kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test`)

- **Impact**:
  26 existing tests fail with:
  `Kargu: invalid application status transition from %S to %S`
  This violates Requirement R3 of `ORIGINAL_REQUEST.md`.

- **Recommended Remedy**:
  In `kargu/application/coordinator.el`:
  1. Expand `kargu-application--transition-table` to include the transitional transitions needed by unmigrated Wave 3 modules (`:idle` to `:executing-tools`, `:verifying`, `:compacting`, `:stopped`; `:stopped` to `:error`, `:requesting`; `:error` to `:requesting`, `:waiting-model`); OR
  2. In `kargu-application-set-status`, allow unvalidated legacy transitions when called on the default singleton without an active owned claim, until Wave 3 completes the engine loop migration.

---

### Empirical Evidence

#### 1. Repository Governance Verification
```bash
$ git diff --stat origin/refactoring -- skills.md .gitignore .agents/
(0 files changed)

$ git status --porcelain skills.md .gitignore
(empty)

$ ls -la .agents/rules/architecture_principles.md
-rw-r--r-- 1 emrehan users 1595 Oct 19 20:00 .agents/rules/architecture_principles.md

$ find . -name "*.elc"
(0 files found)
```

#### 2. Byte-Compilation with Error-on-Warn
Command:
```bash
emacs -Q --batch -L . --eval '(progn
  (require '\''package) (package-initialize)
  (setq byte-compile-error-on-warn t)
  (dolist (f '\''("kargu/application/budget.el" "kargu/application/coordinator.el" ...))
    (let ((elc (byte-compile-dest-file f)))
      (unwind-protect (unless (byte-compile-file f) (error "Compilation failed for %s" f))
        (when (file-exists-p elc) (delete-file elc))))))'
```
Output:
```
Byte-compiling kargu/application/budget.el...
Byte-compiling kargu/application/coordinator.el...
Byte-compiling kargu/application/reset.el...
Byte-compiling kargu/async.el...
Byte-compiling kargu/config.el...
Byte-compiling kargu/config/connection.el...
Byte-compiling kargu/config/key.el...
Byte-compiling kargu/config/schema.el...
Byte-compiling kargu/config/worker.el...
Byte-compiling kargu/contract.el...
Byte-compiling kargu/edit.el...
Byte-compiling kargu/files.el...
Byte-compiling kargu/state/transitions.el...
Byte-compiling kargu/tools/diff.el...
Byte-compiling kargu/tools/diff/context.el...
Byte-compiling kargu/tools/diff/review.el...
Byte-compiling kargu/tools/diff/stage.el...
Byte-compiling kargu/tools/diff/track.el...
Byte-compiling tests/run-tests.el...
Byte-compiling tests/test-application-context.el...
Byte-compiling tests/test-async.el...
Byte-compiling tests/test-helpers.el...
Byte-compiling tests/test-modules.el...
Byte-compiling tests/test-run-budget.el...
Byte-compiling tests/test-connection-snapshot.el...
Byte-compiling tests/test-edit-service.el...
Exited with code 0.
```

#### 3. Formal Model Checking
```
$ ./proof/run_tlc.sh --budget
TLC finished without error (exhaustive run-budget scan).
1591 states generated, 432 distinct states found, 0 states left on queue.

$ ./proof/run_tlc.sh --connection
TLC finished without error (exhaustive connection-snapshot scan).
446212 states generated, 77292 distinct states found, 0 states left on queue.

$ ./proof/run_tlc.sh --edit-transaction
TLC finished without error (exhaustive reviewed edit transaction scan).
1849 states generated, 560 distinct states found, 0 states left on queue.
```

#### 4. ERT Test Suite Run Failure (Acceptance Criteria Check)
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
```
Output:
```
Ran 988 tests, 962 results as expected, 26 unexpected (2026-10-21 22:43:00+0000, 45.264545 sec)

26 unexpected results:
   FAILED  kargu-cache-mutation-invalidates-read-results-test
   FAILED  kargu-dape-compile-final-boundary-rechecks-start-hook-test
   FAILED  kargu-dape-execution-replaced-run-does-not-leak-poll-test
   FAILED  kargu-heal-clean-file-passes-verification-test
   FAILED  kargu-heal-cleanup-keeps-captured-path-after-project-switch-test
   FAILED  kargu-heal-compares-baseline-diagnostics-across-line-shifts-test
   FAILED  kargu-heal-completion-closes-batch-before-next-work-test
   FAILED  kargu-heal-completion-consumes-only-original-records-test
   FAILED  kargu-heal-duplicate-file-callback-cannot-repeat-next-wait-test
   FAILED  kargu-heal-errors-ask-for-a-fix-and-count-a-round-test
   FAILED  kargu-heal-real-diagnostic-wait-cancels-with-batch-test
   FAILED  kargu-heal-startup-error-releases-owned-records-test
   FAILED  kargu-heal-stop-consumes-whole-captured-batch-test
   FAILED  kargu-heal-stop-preserves-new-edit-and-discards-old-reply-test
   FAILED  kargu-heal-timeout-is-not-reported-as-clean-test
   FAILED  kargu-loop-compaction-timeout-asks-to-retry-test
   FAILED  kargu-loop-continue-prompt-test
   FAILED  kargu-loop-doom-approval-after-stop-does-not-run-tool-test
   FAILED  kargu-loop-incomplete-responses-finish-as-errors-test
   FAILED  kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test
   FAILED  kargu-loop-response-continuation-failure-closes-only-its-run-test
   FAILED  kargu-loop-run-call-doom-flow-test
   FAILED  kargu-loop-synchronous-startup-failure-releases-run-test
   FAILED  kargu-lsp-settle-replaced-owner-releases-wait-test
   FAILED  kargu-module-closing-run-owner-cancels-and-rejects-reentry-test
   FAILED  kargu-module-http-cleanup-without-client-or-loop-sources-test
```
Sample Backtrace:
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

---

### Conclusion & Verdict

**Verdict**: **INTEGRITY VIOLATION** (Rejected).
The work product cannot be approved in its current state because it breaks 26 tests in the test suite, directly violating the zero-regression invariant and Acceptance Criterion R3.

Once Worker A updates `kargu/application/coordinator.el` to accommodate the transitional legacy status paths or scopes strict transition validation to owned application contexts, all 988 ERT tests are expected to pass cleanly.
