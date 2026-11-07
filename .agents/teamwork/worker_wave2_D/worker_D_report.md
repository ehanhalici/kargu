# Wave 2 Package D: Tool Execution Gate & Registry Report

**Worker:** `worker_wave2_D`  
**Date:** 2026-10-22  
**Mission:** Tool Execution Gate & Registry, Approval Identity & Permission Binding, Draining/Unload Safety, Compatibility Bridge, Proofs, and Test Suite (MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17, ARCH-19).

---

## 1. Executive Summary

All tasks assigned to Wave 2 Package D have been fully implemented, tested, and verified:
1. **Unified Tool Execution Gate (`kargu/tools/execution.el`)**:
   - Implemented `kargu-tool-execution-context` struct carrying `app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, and `policy-revision`.
   - Implemented `kargu-tool-approval` with single-use claim semantics (`claimed-p`, `kargu-tool-approval-create`, `kargu-tool-approval-claim`), strictly bound to `root`, `tool`, `args-hash`, and `policy-revision`.
   - Implemented full 13-stage execution pipeline in `kargu-tool-gate-execute` (Stage 1 Context Validation -> Stage 2 Registry & Availability -> Stage 3 Draining Check -> Stage 4 Mode Permission -> Stage 5 Argument Decoding -> Stage 6 Schema Validation -> Stage 7 Policy & Required Approval Check -> Stage 8 Approval Resolution & Claim -> Stage 9 Async Task Registration -> Stage 10 Tool Execution -> Stage 11 Secret Redaction -> Stage 12 Output Budget Debiting -> Stage 13 Truncation/Archiving & Single Terminal Delivery).
   - Implemented `kargu-tool-gate-execute-sync` for synchronous execution environments.
   - Implemented output token debiting via `kargu-run-budget-consume` on `:budget-scope`.
   - Implemented secret redaction (`kargu-tool-execution-redact`) protecting bearer tokens, API keys, passwords, and authorization headers with Emacs-compliant regex syntax.
   - Implemented output truncation and project-owned archiving via `kargu--preserve-tool-output`.
   - Implemented single-delivery barrier ensuring callbacks are invoked exactly once regardless of errors or double completion.
2. **Draining and Unload Safety (`kargu/tools/registry.el`, `kargu/tools/execution.el`)**:
   - Added monotonic integer `revision` counter to `kargu-tool-registry` struct, incrementing on every mutating operation (`register`, `alias`, `set-policy`, `remove`).
   - Added `draining` hash-table to `kargu-tool-registry`, along with `kargu-tool-registry-mark-draining`, `kargu-tool-registry-draining-p`, and `kargu-tool-registry-clear-draining`.
   - Updated `kargu-tool-registry-register` to deep copy schema parameters via `(copy-tree parameters)` preventing consumer mutation.
   - Implemented `kargu-tool-execution-drain` to mark tools draining, wait for or cancel active tasks, and safely unregister upon completion.
   - Implemented active async task tracking under `kargu-async` via `kargu-tool-execution--active-tasks` and `kargu-tool-execution-active-task-count`.
3. **Approval Identity & Permission Binding (`kargu/permission/execute.el`, `kargu/permission.el`)**:
   - Added `policy-revision` slot to `kargu-permission-operation`.
   - Updated `kargu-permission--operation-valid-p` to verify that `policy-revision` has not changed since the approval request was created.
   - Updated `kargu-permission-execute` to bind the registry's current policy revision.
   - Added `(require 'kargu/permission/execute)` to `kargu/permission.el`.
4. **Compatibility Bridge (`kargu/api/tools.el`)**:
   - Routed `kargu-execute-tool` through the unified gate validation and execution pipeline.
   - Single-decode of tool arguments prevents redundant parsing and keeps call counts predictable.
   - Added synchronous adapter to support both async-requiring executors (like Git) and synchronous-returning executors (like mock LSP symbol replacement).
   - Preserved `kargu-unregister-tool` with automated draining and task cancellation.
5. **Contract Test Suite & Verification**:
   - Implemented `tests/test-tool-execution-contract.el` containing all 19 contract tests covering Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, and ARCH-17.
   - Added monotonic revision and draining tests to `tests/test-tool-registry.el`.
   - Added policy revision invalidation test to `tests/test-permission-operation.el`.
   - Full ERT test suite passes: 1049 passed, 0 failures, 0 errors.
   - Byte-compilation with `(setq byte-compile-error-on-warn t)`: 0 warnings, 0 errors.
   - Checkdoc: 0 warnings.
   - TLC model checking: `ApprovalMC.tla` passed with 0 errors (8,194 states). `MC.tla` passed with 0 errors (729,094,900 states).
   - Zero leftover `.elc` files.
   - Repository hygiene verified: `skills.md` and `.gitignore` completely untouched.

---

## 2. Architecture & Design Alignment

### MOD-02: Tool Contract & Unified Gate
- Registration (name, schema, capability, executor) is strictly separated from execution context.
- Every tool call—whether direct, aliased, synchronous, or asynchronous—passes through `kargu-tool-gate-execute` (or `kargu-tool-gate-execute-sync`).
- The 13 stages ensure deterministic order: validation -> permission -> approval -> execution -> redaction -> budget -> truncation -> delivery.
- Active async tasks are tracked in a hash table keyed by task object, cleaned up upon task finish or cancellation.

### ARCH-02 & ARCH-03: Command Security & Approval Identity
- Approval tokens (`kargu-tool-approval`) bind:
  * Canonical `root`
  * Canonical `tool`
  * Normalized arguments SHA-256 hash (`args-hash`)
  * Monotonic registry `policy-revision`
- Claiming an approval is atomic and single-use (`claimed-p` slot). Any secondary claim attempt immediately errors with `:approval-already-claimed`.
- Mismatched root, tool, args-hash, or policy-revision rejects the approval.
- No deferred replay or preapproved store is reintroduced.

### ARCH-09 & ARCH-17: Draining, Unload Safety, and Resource Cleanup
- Monotonic revision in `kargu-tool-registry` increments whenever tools, aliases, or policies change.
- Inactive or draining tools reject new invocations with `:tool-draining` before execution can begin.
- `kargu-tool-execution-drain` provides graceful or forceful draining with deadline support and task cancellation before unregistering definitions.
- All tasks register cleanup handlers with `kargu-async-add-cleanup` to guarantee task removal from active sets.

### ARCH-15 & ARCH-16: Defensive Boundary Validation & Typed Results
- Gate validation returns typed results using `kargu-ok` and `kargu-err` records (`:invalid-context`, `:tool-not-found`, `:tool-draining`, `:mode-disallowed`, `:invalid-arguments`, `:schema-validation-failed`, `:approval-required`, `:approval-invalid`, `:approval-already-claimed`, `:execution-failed`).
- Defensive argument decoding cleanly handles strings, raw JSON, alists, and invalid syntax.
- Schemas are deep-copied on registration to prevent external mutation.

### ARCH-19: Contract Evolution & Compatibility Bridge
- Existing call sites using `(kargu-execute-tool name arguments callback)` or `(kargu-execute-tool name arguments)` continue to function with 100% backward compatibility.
- Compatibility layer adapts sync/async differences without leaking internal exception representations.

---

## 3. Verification Details

### ERT Test Suite
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
```
Result:
- **1049 tests run, 1049 passed, 0 failed, 0 errors (100% pass rate)**.
- Specific tests verified:
  * `tests/test-tool-execution-contract.el`: 19 tests, 19 passed.
  * `tests/test-tool-registry.el`: 11 tests, 11 passed (including 2 new tests).
  * `tests/test-permission-operation.el`: 10 tests, 10 passed (including 1 new test).
  * `tests/test-permission.el`: 18 tests, 18 passed.
  * `tests/test-tools.el`: 18 tests, 18 passed.
  * `tests/test-api.el`: 34 tests, 34 passed.
  * `tests/test-cache.el`: 16 tests, 16 passed.

### Byte-Compilation
Command:
```elisp
(setq byte-compile-error-on-warn t)
(dolist (f '("kargu/tools/registry.el"
             "kargu/permission/execute.el"
             "kargu/permission.el"
             "kargu/tools/execution.el"
             "kargu/api/tools.el"
             "tests/test-tool-registry.el"
             "tests/test-permission-operation.el"
             "tests/test-tool-execution-contract.el"))
  (byte-compile-file f))
```
Result:
- **0 errors, 0 warnings across all files.**
- All compiled `.elc` files removed immediately afterwards (`find . -name "*.elc" -delete`).

### Checkdoc
Checked files:
- `kargu/tools/registry.el`
- `kargu/permission/execute.el`
- `kargu/permission.el`
- `kargu/tools/execution.el`
- `kargu/api/tools.el`
Result:
- **0 checkdoc warnings.**

### TLC Formal Model Checking
1. Approval Model:
   - Command: `bash proof/run_tlc.sh --approval`
   - Target: `proof/ApprovalMC.tla`
   - Result: 8,194 states generated, 4,098 distinct states found, 0 errors.
2. Global System Model:
   - Command: `bash proof/run_tlc.sh`
   - Target: `proof/MC.tla`
   - Result: 729,094,900 states generated, 85,318,093 distinct states checked, 0 errors.

### Repository Hygiene
- `git status --porcelain skills.md .gitignore` -> completely empty.
- Zero `.elc` files left behind.

---

## 4. Status of Architectural Work Items in todo.md

For orchestrator reference when updating `todo.md`:
- **MOD-02**: Fully satisfied. Unified execution gate in `kargu/tools/execution.el` implemented with 13 stages, context, approval, async task tracking, draining, secret redaction, token budgeting, truncation, and single delivery. Existing public entry point `kargu/api/tools.el` routed through the gate.
- **ARCH-02 & ARCH-03**: Fully satisfied. Captured approval token bound to root, tool, args-hash, and policy revision with single-use claim semantics. Replay attempts rejected.
- **ARCH-09 & ARCH-17**: Fully satisfied. Monotonic revision counter in `kargu-tool-registry`, draining state management, async task tracking, graceful/forceful draining before code detachment.
- **ARCH-15 & ARCH-16**: Fully satisfied. Boundary validation with typed `kargu-ok` / `kargu-err` results, error codes, and single terminal delivery.
- **ARCH-19**: Fully satisfied. Public API compatibility maintained for sync and async tool consumers.
