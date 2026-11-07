# Handoff Report: Wave 2 Package D — Tool Execution Gate & Registry

**Agent:** `worker_wave2_D`  
**Parent Agent:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T03:55:00Z  
**Type:** Hard Handoff (Task Complete)

---

## 1. Observation

1. **Source Code Modifications and New Files**:
   - `kargu/tools/registry.el`: Added `revision` (integer, default 0) and `draining` (hash-table) slots to `kargu-tool-registry` struct. Added `kargu-tool-registry-mark-draining`, `kargu-tool-registry-draining-p`, and `kargu-tool-registry-clear-draining`. Mutating functions (`register`, `alias`, `set-policy`, `remove`) increment `revision` and manage `draining`. `kargu-tool-registry-register` performs `(copy-tree parameters)` to ensure schema immutability against consumer mutation.
   - `kargu/permission/execute.el`: Added `policy-revision` slot to `kargu-permission-operation`. Updated `kargu-permission--operation-valid-p` to verify `(or (null policy-revision) (eql policy-revision (kargu-tool-registry-revision kargu--tool-registry)))`. Extended `kargu-permission-execute` with optional keyword `:policy-revision`.
   - `kargu/permission.el`: Added `(require 'kargu/permission/execute)`.
   - `kargu/tools/execution.el`: Created new 13-stage execution gate. Defined `kargu-tool-execution-context` struct (`app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, `policy-revision`). Defined `kargu-tool-approval` struct (`id`, `root`, `tool`, `args-hash`, `policy-revision`, `created-at`, `claimed-p`) with single-use claim semantics. Implemented `kargu-tool-gate-execute` (13 stages), `kargu-tool-gate-execute-sync`, `kargu-tool-execution-drain`, `kargu-tool-execution-active-task-count`, secret redaction (`kargu-tool-execution-redact`), output token budgeting debit via `kargu-run-budget-consume`, truncation/archiving via `kargu--preserve-tool-output`, and terminal single-delivery barrier.
   - `kargu/api/tools.el`: Replaced ad-hoc checks in `kargu-execute-tool` with `kargu-tool-execution--validate-gate` and unified gate dispatching. Decode arguments once via `kargu-tool-execution-decode-arguments` before gate validation. Synchronous boundary handles async-requiring executors (returning error string for invalid synchronous calls) and synchronous tool execution (returning strings directly). Updated `kargu-unregister-tool` to drain and cancel active tasks via `kargu-tool-execution-drain`.
2. **Test Suites**:
   - `tests/test-tool-execution-contract.el`: Implemented 19 contract tests covering Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17.
   - `tests/test-tool-registry.el`: Added `kargu-tool-registry-revision-increments-monotonically-test` and `kargu-tool-registry-draining-state-management-test`.
   - `tests/test-permission-operation.el`: Added `revision` check to `kargu-permission-owned-operation-invalidates-obsolete-authority-test`.
3. **Execution Results & Verbatim Outputs**:
   - ERT Test Suite:
     Command: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
     Verbatim output: `Ran 1049 tests, 1049 results as expected, 0 unexpected (2026-10-22 03:54:14+0000, 44.201325 sec)`.
   - Byte-compilation with error-on-warning:
     Command: `(setq byte-compile-error-on-warn t)` on all 8 affected and new files.
     Result: 0 errors, 0 warnings.
   - Checkdoc: Clean on all production files (`kargu/tools/registry.el`, `kargu/permission/execute.el`, `kargu/permission.el`, `kargu/tools/execution.el`, `kargu/api/tools.el`).
   - Formal Model Checking (TLC):
     `bash proof/run_tlc.sh --approval` -> 8,194 states generated, 4,098 distinct states found, 0 errors.
     `bash proof/run_tlc.sh` -> 729,094,900 states generated, 85,318,093 distinct states checked, 0 errors.
   - Zero Leftover `.elc`:
     `find . -name "*.elc"` -> 0 matches.
   - Repository Hygiene:
     `git status --porcelain skills.md .gitignore` -> completely empty.

---

## 2. Logic Chain

1. From Observation 1, the unified gate in `kargu/tools/execution.el` implements all 13 stages described in Contract 5: context validation, registry/availability, draining check, mode permission, argument decoding, schema validation, policy approval check, approval identity/claim resolution, async task tracking, tool execution, secret redaction, output token budgeting, and output truncation/archiving with single terminal delivery.
2. From Observation 1 and 2, `kargu-tool-approval` enforces single-use claim semantics (`claimed-p`) and binds to canonical root, canonical tool, SHA-256 args hash, and monotonic policy revision. Therefore, replay attempts, root mutations, argument modifications, and post-approval policy shifts are rejected (satisfying ARCH-02 and ARCH-03).
3. From Observation 1, `kargu-tool-registry` manages monotonic revision and draining state. Draining tools reject incoming invocations, and `kargu-tool-execution-drain` ensures active tasks finish or are cancelled before code detachment (satisfying ARCH-09 and ARCH-17).
4. From Observation 1, `kargu/api/tools.el` delegates tool execution to the unified gate while preserving existing public API compatibility for both synchronous and asynchronous callers, with single argument decoding (satisfying ARCH-19 and MOD-02).
5. From Observation 2 and 3, all 1049 ERT tests pass without errors or regressions, byte compilation has zero warnings under `byte-compile-error-on-warn t`, checkdoc has zero warnings, TLC model checks pass with zero errors, and repository hygiene is preserved.

---

## 3. Caveats

- Feature tool implementations (`kargu/tools/git.el`, `diff.el`, `bash.el`, `search.el`, `lsp/*`, `dape/*`) were intentionally not modified, per dispatch instructions. Their internal logic remains intact and functions correctly through the unified gate adapter.
- In `kargu/tools/execution.el`, when `:budget-scope` is provided, `kargu-run-budget-consume` is invoked with `:tokens output-tokens`. If `:budget-scope` is nil, token budgeting is skipped.
- No caveats regarding completeness or correctness of the 13-stage gate and registry contract.

---

## 4. Conclusion

Wave 2 Package D is 100% complete, fully verified, and ready for integration. All requirements (MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17, ARCH-19) are satisfied.

---

## 5. Verification Method

To independently verify the implementation:

1. **Run full ERT test suite**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
   ```
   *Expected:* 1049 tests run, 1049 passed, 0 failures, 0 errors.

2. **Run Package D contract test suite specifically**:
   ```bash
   emacs -Q --batch -L . -l tests/test-tool-execution-contract.el -f ert-run-tests-batch-and-exit
   ```
   *Expected:* 19 tests run, 19 passed.

3. **Verify byte-compilation cleanly with zero warnings**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (setq byte-compile-error-on-warn t) (dolist (f (list "kargu/tools/registry.el" "kargu/permission/execute.el" "kargu/permission.el" "kargu/tools/execution.el" "kargu/api/tools.el" "tests/test-tool-registry.el" "tests/test-permission-operation.el" "tests/test-tool-execution-contract.el")) (byte-compile-file f)))'
   find . -name "*.elc" -delete
   ```
   *Expected:* Exit code 0, 0 warnings.

4. **Run TLC formal verification**:
   ```bash
   bash proof/run_tlc.sh --approval
   ```
   *Expected:* Model checking completed with 0 errors.

5. **Verify repository hygiene**:
   ```bash
   git status --porcelain skills.md .gitignore
   find . -name "*.elc"
   ```
   *Expected:* Both commands output nothing.
