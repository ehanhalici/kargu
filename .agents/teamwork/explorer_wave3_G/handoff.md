# Hard Handoff Report: Wave 3 Package G Architectural Exploration
**From**: `explorer_wave3_G`  
**To**: Orchestrator (`teamwork_preview_orchestrator` / `246e42bd-e1b7-4f73-8026-d90704dd17ec`) & `worker_wave3_G`  
**Date**: 2026-10-22T04:50:30Z  
**Type**: Hard Handoff (Investigation & Blueprint Complete)  
**Status**: Certified Ready for Implementation  

---

## 1. Observation

1. **Existing Baseline Test Suite State**:
   - Command: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Output: `Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:45:19+0000, 44.803084 sec)`. 0 failures, 0 errors.
2. **Buffer Coupling in `kargu/loop.el`**:
   - Lines 84–94: `(defun kargu-loop--attach-origin (run) (let ((origin (plist-get run :chat-buffer)) ...) (with-current-buffer origin (add-hook 'kill-buffer-hook cleanup nil t) ...)))`.
   - Lines 341–343: `(defun kargu--loop-finish (run status &optional text) (let ((origin (plist-get run :chat-buffer))) (with-current-buffer (if (buffer-live-p origin) origin (current-buffer)) ...)))`.
   - When running headless or from batch mode, `:chat-buffer` is nil or non-chat buffer, attaching hooks or switching buffers needlessly.
3. **Application & Claim Lifecycle Gap**:
   - `kargu/application/coordinator.el` lines 277–308 defines `kargu-application-claim` and lines 310–341 defines `kargu-application-release`.
   - `kargu/loop.el` lines 282–295 calls `(kargu-application-set-active-run run)` but does not acquire a claim token or bind to an explicit `kargu-application` instance passed by the caller.
4. **Tool Execution Gate Decoupling**:
   - `kargu/loop/tools.el` lines 174–176: `(if-let* ((gate (kargu-loop--gate-tool name))) (funcall on-result gate) (kargu-execute-tool name args on-result))`.
   - `kargu/tools/execution.el` lines 418–450 exposes `(kargu-tool-gate-execute registry context name raw-args &key callback approval)`, which provides unified 13-stage validation, mode gating, availability checking, and output budgeting.
5. **Run Budget Accounting Gap (Contract 6 & DEEP-09)**:
   - `kargu/application/budget.el` lines 80–145 defines `(kargu-budget-debit budget debit-type &key requests tokens)` supporting `:normal-request`, `:retry-attempt`, `:compaction-turn`, `:healing-turn`, `:continuation`.
   - `kargu/api/http.el` lines 246–254 debits `debit-type` based solely on `(if (> attempt 0) :retry-attempt :normal-request)`. Compaction turns (`kargu/loop/compact.el` lines 61–64) and continuation nudges (`kargu/loop/machine.el` line 401) call `kargu-api-send` without specifying `debit-type`, meaning compaction does not debit `:compaction-turn` and does not track `compactions-spent` in `kargu-run-budget`.
6. **Confirmation Port Headless Invariant**:
   - `kargu/confirm.el` lines 25–31: `(defun kargu-present-confirmation (request) (when (eq (kargu-confirmation-operation request) :prompt) (let ((options (kargu-confirmation-options request))) (funcall (plist-get options :on-decision) (or (plist-get options :default-action) :stop)))))`.
   - In headless execution, without a presentation adapter, confirmations safely evaluate their default action (`:stop` or `:reject`) synchronously without blocking.
7. **Baseline Diagnostics Status**:
   - `kargu/loop/heal.el` lines 123–129 sets `:baseline-available nil` when baseline is unavailable, but does not explicitly output status `:unknown`, risking ambiguous reporting.
8. **Formal Verification Invariants**:
   - `proof/run_tlc.sh --budget` (BudgetMC.tla) passed cleanly (1591 states, 432 distinct states).
   - `proof/run_tlc.sh --verification` (VerificationMC.tla) passed cleanly (439 states, 68 distinct states).

---

## 2. Logic Chain

1. **Premise 1 (Single Active Run & Decoupling)**: ARCH-01 and ARCH-12 require all runtime state to be anchored in an explicit `kargu-application` coordinator rather than mutable globals.
   - *Inference*: `kargu-loop-send` must accept optional `:app`, `:budget`, `:chat-buffer`, `:mode`, and `:observers` parameters. It must acquire an exclusive claim via `kargu-application-claim` at launch, verify `(not (kargu-application-work-active-p app))`, and release the claim on finish.
2. **Premise 2 (Headless Independence)**: MOD-01 mandates that core headless engine loops run cleanly without chat/UI buffers or global UI pending lists.
   - *Inference*: When `:chat-buffer` is nil or invalid, `kargu-loop--attach-origin` and buffer switching in finish/receive/stop handlers must be no-ops. `kargu-confirm` calls must continue to safely evaluate `:default-action` without blocking.
3. **Premise 3 (Structured Events & Single Terminal Event)**: Contract 7 dictates immutable `kargu-passive-event` structures with `kargu-event-id`, monotonic sequence numbers, observer error protection, and strictly ONE `:run-finish` event per run.
   - *Inference*: A dedicated `kargu-loop-emit-event` dispatcher must be added, setting `(plist-put run :finished-p t)` upon terminal finish to guarantee no post-terminal events leak to observers.
4. **Premise 4 (Unified Run Budget)**: Contract 6 and DEEP-09 require all operations in an agent run (normal turns, retries, healing, compaction, continuation) to debit against a single `kargu-run-budget`.
   - *Inference*: `kargu-api-send` and `kargu--api-post` must accept and respect `:debit-type`. Compaction turns in `kargu/loop/compact.el` must specify `:compaction-turn` and guard against second overflow. Healing turns in `kargu/loop/heal.el` must specify `:healing-turn`. Continuations in `kargu/loop/machine.el` and `kargu/loop/ui.el` must specify `:continuation`. Loop retries must specify `:retry-attempt`.
5. **Premise 5 (Tool Execution Gate)**: Contract 5 mandates all tool calls execute via Package D's unified 13-stage gate in `kargu/tools/execution.el`.
   - *Inference*: `kargu/loop/tools.el` must construct `kargu-tool-execution-context` (binding `app`, `run-id`, `session-id`, `root`, `mode`, `budget`) and call `kargu-tool-gate-execute` directly.
6. **Premise 6 (Baseline Diagnostics Integrity)**: DEEP-01 requires reporting `unknown` rather than fabricating clean state when baseline diagnostics are unavailable.
   - *Inference*: `kargu/loop/heal.el` must report status as `:unknown` whenever baseline comparison is unavailable.

---

## 3. Caveats

1. **Concurrent Wave 3 Packages**: Package H (`kargu/chat.el`, `kargu/plan.el`, UI) and Package I (`kargu/core/log.el`, `kargu/core/redact.el`) are active concurrently. Package G must write ONLY to its designated allowlist files:
   `kargu/loop.el`, `kargu/loop/machine.el`, `kargu/loop/tools.el`, `kargu/loop/ui.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`, `kargu/history.el`, `kargu/history/store.el`, `kargu/history/protocol.el`, `kargu/history/repair.el`, `kargu/history/compact.el`, `kargu/prompt.el`, `kargu/prompt/default.txt`, and new test files `tests/test-headless-events.el` and `tests/test-budget-composition.el`.
   Package G MUST NOT touch `kargu/chat.el`, `kargu/ui.el`, `kargu/plan.el`, or `kargu/core/log.el`.
2. **Backwards Compatibility**: The public signature of `kargu-loop-send` (`prompt &optional on-delta on-finish`) must remain callable without keywords; new parameters (`&key app budget chat-buffer mode observers`) must be optional.

---

## 4. Conclusion

The architecture, contract boundaries, data structures, and concrete code blueprints for Wave 3 Package G are fully designed and validated. All baseline tests pass (1052/1052). Worker G has a precise, self-contained implementation plan in `package_G_report.md`.

---

## 5. Verification Method

### 1. ERT Test Execution
Run the full test suite including the two new test suites:
```bash
emacs -Q --batch -L . --eval '(progn (require '\''package) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
```
Expected result: 1052+ tests, 0 failures, 0 errors.

### 2. New Test Suites Verification
Run the specific new Package G test suites:
```bash
emacs -Q --batch -L . -l tests/test-headless-events.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -l tests/test-budget-composition.el -f ert-run-tests-batch-and-exit
```

### 3. Byte-Compilation Zero-Warning Gate
```bash
emacs -Q --batch -L . --eval '(progn (setq byte-compile-error-on-warn t) (dolist (f (directory-files-recursively "kargu" "\\.el$")) (byte-compile-file f t)))'
```
Ensure all `.elc` files are cleaned up:
```bash
find . -name "*.elc" -delete
```

### 4. Formal Model Checking
```bash
./proof/run_tlc.sh --budget
./proof/run_tlc.sh --verification
./proof/run_tlc.sh --transport
```
Expected result: All model checks complete with 0 errors.
