# Wave 0 Coordinator Worker Implementation & Verification Report

**Author**: `teamwork_preview_worker_wave0_1` (Wave 0 Coordinator Worker)  
**Date**: 2026-10-21  
**Milestone**: Wave 0: Coordinator Boundaries & Fixtures  
**Reference**: `parallel-plan.md` §3, `ORIGINAL_REQUEST.md`, `PROJECT.md`

---

## 1. Executive Summary

All Wave 0 deliverables assigned to the coordinator worker have been implemented, verified, and validated with zero regressions, zero compiler warnings, zero checkdoc linter warnings, and 100% formal verification passes across all TLA+/TLC models.

Key outcomes:
1. **Public File Revision API**: `kargu-file-current-revision` implemented in `kargu/files.el`; `kargu-diff--disk-revision` in `kargu/tools/diff/track.el` switched to the public function, eliminating the sole cross-boundary private function call in production code.
2. **Authoritative Architecture Contracts**: `architecture-contracts.md` published at repository root establishing canonical specifications for all 8 core boundary contracts.
3. **Complete Contract Facade**: `kargu/contract.el` updated to require all 7 contract submodules (`constants`, `result`, `types`, `assert`, `file-window`, `history`, `selection`).
4. **Single-Active-Run Invariant (ARCH-01/12)**: `kargu-application-set-active-run` now rejects conflicting active runs; added `kargu-application-claim` and `kargu-application-release` lifecycle token management in `kargu/application/coordinator.el`.
5. **Dual-Application Test Fixtures**: `kargu-test-make-dual-applications` and `kargu-test-with-dual-applications` added to `tests/test-helpers.el`.
6. **Subprocess Boundary Tests**: `kargu-module-all-contracts-independent-test` and `kargu-module-dual-application-isolation-test` added to `tests/test-modules.el`.
7. **Dedicated Context Isolation Suite**: `tests/test-application-context.el` created with 4 isolation tests.
8. **Test Suite Expansion & Zero Regressions**: Total ERT test count grew from 942 to 948 passing tests (0 failures, 0 errors).
9. **Zero Byte-Compilation & Checkdoc Warnings**: All modified and new Elisp files compile with `(setq byte-compile-error-on-warn t)` with zero warnings; checkdoc clean; zero leftover `.elc` files.
10. **Exhaustive TLC Model Verification**: `proof/run_tlc.sh --mode` (5,958 distinct states) and `proof/run_tlc.sh --edit-transaction` (160 distinct states) passed without error.
11. **Repository Hygiene**: Untracked/modified `skills.md`, `.gitignore`, and `.agents/` preserved completely untouched and unstaged.

---

## 2. File-by-File Changes and Rationale

### 2.1 `kargu/files.el`
- **Change**: Added public `(kargu-file-current-revision path)` handling file paths (string) and live file-visiting buffers. Returns `kargu-file-revision` struct on valid, readable file snapshots; returns `nil` on unreadable, absent, or remote targets without throwing unhandled exceptions.
- **Change**: Refactored private `kargu-file--file-revision` to delegate directly to `(or (kargu-file-current-revision path) (error "File disappeared while reading its snapshot"))`, preserving 100% backward compatibility for internal consumers in `kargu-file--disk-excerpt`.

### 2.2 `kargu/tools/diff/track.el`
- **Change**: In `kargu-diff--disk-revision`, replaced `(when (file-exists-p path) (ignore-errors (kargu-file--file-revision path)))` with `(kargu-file-current-revision path)`.
- **Rationale**: Removes private encapsulation breach into `kargu/files.el` ahead of Wave 1 Package B.

### 2.3 `architecture-contracts.md`
- **Change**: Written authoritative markdown inventory at repository root based on `spec_miner_wave0_2/architecture-contracts.md`.
- **Content**: Details the 8 core contracts (Application, Async Scope, Edit, Connection, Tool Gate, Budget, Events, Results), domain error codes, lifecycle transitions, acceptance gates, and contract-to-package mapping matrix.

### 2.4 `kargu/contract.el`
- **Change**: Added `(require 'kargu/contract/file-window)`, `(require 'kargu/contract/history)`, and `(require 'kargu/contract/selection)`.
- **Rationale**: Ensures requiring `kargu/contract` loads all 7 submodules without pulling any runtime, state, or feature code.

### 2.5 `kargu/application/coordinator.el`
- **Change**: Updated `kargu-application` struct with `session-id` and `run-id` slots; updated `kargu-application-create` constructor.
- **Change**: Enforced single-active-run rejection in `kargu-application-set-active-run` when a different run is already active on `target`.
- **Change**: Defined `kargu-application-claim` struct and constructor.
- **Change**: Implemented `(kargu-application-claim app &rest plist)`: claims execution, sets `active-run` and status `:running`, signals error if already claimed (or returns `nil` with `:no-error t`).
- **Change**: Implemented `(kargu-application-release app claim)`: releases matching claim and returns `t`, returns `nil` on mismatch.
- **Change**: Updated `kargu-application-set-active-request` to align application generation with incoming logical request generation.

### 2.6 `tests/test-helpers.el`
- **Change**: Required `cl-lib` at top level.
- **Change**: Implemented `kargu-test-make-dual-applications` and macro `kargu-test-with-dual-applications` guaranteeing clean unwind reset for dual application contexts.

### 2.7 `tests/test-modules.el`
- **Change**: Added `kargu-module-all-contracts-independent-test` verifying all 8 contract features load cleanly in clean subprocesses without forbidden runtime features.
- **Change**: Added `kargu-module-dual-application-isolation-test` verifying dual application isolation and second-run rejection in a fresh batch subprocess.

### 2.8 `tests/test-application-context.el`
- **Change**: Created new test suite with 4 comprehensive isolation and lifecycle tests:
  1. `kargu-application-dual-instance-isolation-test`
  2. `kargu-application-logical-request-isolation-test`
  3. `kargu-application-single-active-run-rejected-test`
  4. `kargu-application-claim-and-release-lifecycle-test`

### 2.9 `tests/run-tests.el`
- **Change**: Added `(require 'tests/test-application-context)` to the suite runner.

---

## 3. Verification Commands and Results

### 3.1 ERT Test Suite
- **Command**:
  ```bash
  emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
  ```
- **Result**:
  ```
  Ran 948 tests, 948 results as expected, 0 unexpected (43.89 sec)
  ```

### 3.2 Byte-Compilation with Warning-as-Error
- **Command**:
  ```bash
  emacs -Q --batch -L . -L tests --eval '
  (progn
    (require '\''package)
    (package-initialize)
    (require '\''bytecomp)
    (setq byte-compile-error-on-warn t)
    (dolist (f '\''("kargu/files.el" "kargu/tools/diff/track.el" "kargu/contract.el"
                   "kargu/application/coordinator.el" "tests/test-helpers.el"
                   "tests/test-modules.el" "tests/test-application-context.el"
                   "tests/run-tests.el"))
      (let ((elc (byte-compile-dest-file f)))
        (unwind-protect
            (byte-compile-file f)
          (when (file-exists-p elc) (delete-file elc))))))'
  ```
- **Result**: 0 errors, 0 warnings.
- **Leftover Check**: `find . -name "*.elc"` produces 0 output lines.

### 3.3 Checkdoc Linting
- **Command**:
  ```bash
  emacs -Q --batch -L . -L tests --eval '
  (progn
    (require '\''checkdoc)
    (dolist (f '\''("kargu/files.el" "kargu/tools/diff/track.el" "kargu/contract.el"
                   "kargu/application/coordinator.el" "tests/test-helpers.el"
                   "tests/test-modules.el" "tests/test-application-context.el"
                   "tests/run-tests.el"))
      (with-current-buffer (find-file-noselect f)
        (checkdoc-current-buffer t)
        (when (get-buffer "*checkdoc-warnings*")
          (with-current-buffer "*checkdoc-warnings*"
            (when (> (buffer-size) 0)
              (message "WARN in %s: %s" f (buffer-string))
              (erase-buffer)))))))'
  ```
- **Result**: 0 warnings.

### 3.4 TLC Formal Model Checking
1. **Mode State Machine**:
   - `bash proof/run_tlc.sh --mode`
   - Output: 20,179 states generated, 5,958 distinct states found. TLC finished without error.
2. **Edit Transaction Protocol**:
   - `bash proof/run_tlc.sh --edit-transaction`
   - Output: 425 states generated, 160 distinct states found. TLC finished without error.

### 3.5 Working Tree Protection
- `git status --short`:
  Confirmed `skills.md`, `.gitignore`, and `.agents/` remain unstaged and unchanged.

---

## 4. Conclusion
Wave 0 baseline boundaries, contracts, and test fixtures are fully established. The repository is in a clean, robust, and verified state ready for Wave 1 parallel workers (Package A, Package B, and Package C).
