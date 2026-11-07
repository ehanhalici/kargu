# Architectural Blueprint & Investigation Report: Wave 2 Package D
## Tool Execution Gate & Registry (MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17, ARCH-19)

**Author:** `explorer_wave2_D_2`  
**Milestone:** Wave 2, Package D  
**Target Module:** `kargu/tools/execution.el` (New Unified Gate), `kargu/tools/registry.el`, `kargu/api/tools.el`, `kargu/permission/execute.el`  
**Target Tests:** `tests/test-tool-execution-contract.el`  
**Formal Specifications:** `proof/KarguApproval.tla`, `proof/ApprovalMC.tla`, `proof/ApprovalMC.cfg`, `proof/KarguTools.tla`  

---

## 1. Executive Summary & Context

Under Wave 0 and Wave 1, Kargu established contract boundaries (`architecture-contracts.md`), application context ownership (`kargu/application/coordinator.el`), run budgets (`kargu/application/budget.el`), and connection snapshots (`kargu/config/connection.el`).

Wave 2 Package D establishes the **Single Unified Gate** for all tool execution, registration, and permission enforcement.
Currently, tool execution is fractured across multiple ad-hoc layers:
1. `kargu/api/tools.el` holds a global default registry (`kargu--tool-registry`), ad-hoc async wrapping, and truncation/archiving logic, but does NOT perform permission gating, mode checks for mutating tools, or single-use approval verification.
2. `kargu/loop/tools.el` implements its own mode gating (`kargu-loop--gate-tool`), doom loop detection, and after-tool diagnostic verification.
3. `kargu/permission/execute.el` and individual tools (`bash.el`, `git.el`) independently perform approval checks and process runs, rather than converging on a single owned execution gate.
4. Output budgeting is disconnected from Package A's `kargu-run-budget` (`kargu/application/budget.el`).
5. Tool unloading/deregistration (`kargu-unregister-tool`) removes definitions while active asynchronous operations may still be running, violating ARCH-09 and ARCH-17.

Package D unifies all of these paths into `kargu/tools/execution.el`:
- **Composition-Owned Registry**: Registry instances are explicitly owned and passed via context; definitions, aliases, and monotonic revisions are cleanly decoupled from mutable pending execution instances.
- **Context-Carrying Async Gate**: `kargu-tool-gate-execute` accepts `kargu-tool-execution-context` (carrying `app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, and `policy-revision`).
- **All Invariants Enforced in One Place**:
  1. Canonical resolution & alias flattening (aliases cannot bypass permission/mode checks).
  2. Mode checks (mutating tools strictly forbidden in `ask` / `plan` modes).
  3. Availability policy checks (`:available-p`).
  4. Parameter schema validation & object normalization.
  5. Run budget accounting & pre-check (consuming `kargu-run-budget`).
  6. Single-use captured approval verification (`kargu-tool-approval`, no replay/preapproved cache).
  7. Async task tracking under `kargu-async` with cancellation and single-delivery guarantees.
  8. Output redaction of secrets prior to storage, logging, or delivery.
  9. Output bounding, truncation, and project-owned archiving quota management.
  10. Output budget token debiting.
- **Safe Draining & Unload**: Unregistering or disabling a tool marks it `:draining` and drains/cancels active work before code detachment (ARCH-09).
- **Backward Compatibility**: `kargu-execute-tool` in `kargu/api/tools.el` is preserved as a boundary facade delegating to the unified gate.

---

## 2. Investigation & Baseline Observations

### 2.1 File & Responsibility Audit

| File | Current Role | Deficiencies / Architectural Debt |
|------|--------------|----------------------------------|
| `kargu/tools/registry.el` | Explicit registry struct (`entries` hash-table) | Lacks monotonic revision counter, lacks draining state, no active task tracking. |
| `kargu/api/tools.el` | Global registry singleton `kargu--tool-registry`, `kargu-execute-tool`, truncation | Global mutable singleton; direct executor invocation bypasses approval tokens, mode checks, and budget debits. |
| `kargu/permission.el` | Facade requiring `guards`, `bash`, `policy` | Facade only. |
| `kargu/permission/guards.el` | Project root resolution, path confinement | Uses dynamic override `kargu-permission--override-root` rather than reading canonical root from context. |
| `kargu/permission/policy.el` | Interactive approval via `kargu-confirm` | Hardcodes bash approval UI; not generalized to any guarded tool. |
| `kargu/permission/execute.el` | Single-use approval operation (`kargu-permission-operation`) | Binds process-environment, directory, and loop-run, but not tied to tool registry revision or capability snapshot. |
| `kargu/confirm.el` | Non-blocking confirmation abstraction | Properly rejects in non-interactive batch unless mocked. |
| `kargu/application/budget.el` | Run budget struct and debit gate | Provides `kargu-budget-debit` and `kargu-budget-record-tokens`; not consumed by tool outputs currently. |

### 2.2 Baseline Verification Metrics
- **ERT Test Suite**: 997 tests ran, 997 passed, 0 failures, 0 errors (`emacs -Q --batch -L . ... -f ert-run-tests-batch-and-exit`).
- **Scope File Compilation**: `kargu/tools/registry.el`, `kargu/api/tools.el`, `kargu/permission/*.el`, `kargu/confirm.el` byte-compile with 0 warnings under `(setq byte-compile-error-on-warn t)`.
- **TLC Model Checking**:
  - `proof/run_tlc.sh --approval`: 8,194 states generated, 1,536 distinct states, 0 errors, depth 11.
  - `proof/run_tlc.sh --simulate 10000`: 2,795,038 states checked, 0 errors (covers `KarguTools.tla` and `KarguLoop.tla`).

---

## 3. Architecture & Data Flow of the Unified Execution Gate

```
                  kargu-tool-gate-execute(registry, context, name, raw-args, :callback cb, :approval appr)
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 1. Validate Registry & Ctx   │
                                       │    kargu-tool-registry-p     │
                                       │    kargu-execution-context-p │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 2. Canonical Resolution      │
                                       │    kargu-tool-registry-find  │
                                       │    Flatten aliases           │
                                       │    Reject if draining/absent │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 3. Mode Gate                 │
                                       │    (memq mode policy-modes)  │
                                       │    Mutating tool check       │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 4. Availability Check        │
                                       │    (funcall :available-p)    │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 5. Budget Pre-Check          │
                                       │    (kargu-budget-live-p)     │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 6. Argument Decoding & Schema│
                                       │    kargu--decode-arguments   │
                                       │    kargu-contract-tool-schema│
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 7. Captured Approval Check   │
                                       │    Single-use claim (claimed)│
                                       │    Verify: tool, root, rev,  │
                                       │            env, args-hash    │
                                       │    Ask user if missing       │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 8. Async Task & Active Track │
                                       │    kargu-async-start         │
                                       │    Register in active-tasks  │
                                       │    Add cleanup to untrack    │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 9. Dispatch Executor         │
                                       │    Sync (1-arg) or           │
                                       │    Async (2-arg on-done)     │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼ [Result Arrives]
                                       ┌──────────────────────────────┐
                                       │ 10. Output Redaction         │
                                       │     Mask secrets & tokens    │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 11. Output Budget Accounting │
                                       │     Debit tokens to budget   │
                                       │     Check deadline           │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 12. Bounding & Archiving     │
                                       │     Truncate to limit        │
                                       │     Archive in *kargu-out-N* │
                                       │     Prune oldest archives    │
                                       └──────────────┬───────────────┘
                                                      │
                                                      ▼
                                       ┌──────────────────────────────┐
                                       │ 13. Terminal Single Delivery │
                                       │     kargu-async-finish       │
                                       │     Untrack active task      │
                                       └──────────────────────────────┘
```

---

## 4. Detailed Specification of Data Structures & Signatures

### 4.1 Data Structures

#### 4.1.1 `kargu-tool-execution-context`
```elisp
(cl-defstruct (kargu-tool-execution-context
               (:constructor kargu-tool-execution-context--create))
  "Context passed to tool execution gate."
  (context-id (format "exec-%s" (kargu-random-uuid)) :read-only t)
  (app nil :read-only t)               ; kargu-application instance
  (run-id nil :read-only t)            ; string run identifier
  (session-id nil :read-only t)        ; string session identifier
  (root default-directory :read-only t); canonical project root path
  (mode 'agent :read-only t)           ; symbol in `kargu-all-modes'
  (budget-scope nil :read-only t)      ; kargu-run-budget instance or nil
  (policy-revision 0 :read-only t))    ; integer revision of policy/config
```

#### 4.1.2 `kargu-tool-approval`
```elisp
(cl-defstruct (kargu-tool-approval
               (:constructor kargu-tool-approval--create))
  "Single-use captured approval token for guarded execution."
  (token-id (format "appr-%s" (kargu-random-uuid)) :read-only t)
  (tool-name nil :read-only t)         ; canonical tool name string
  (args-hash nil :read-only t)         ; sha256 hash string of decoded args
  (root nil :read-only t)              ; canonical project root directory
  (policy-revision 0 :read-only t)     ; integer registry/policy revision
  (environment-hash nil :read-only t)  ; sha256 of process-environment
  (claimed-p nil))                     ; mutable boolean: t once consumed
```

#### 4.1.3 Updates to `kargu-tool-registry` in `kargu/tools/registry.el`
```elisp
(cl-defstruct (kargu-tool-registry (:constructor kargu-tool-registry-create ()))
  "Owned registry of canonical definitions and flattened alias names."
  (entries (make-hash-table :test #'equal) :read-only t)
  (revision 0)                                            ; Monotonic integer revision
  (draining (make-hash-table :test #'equal) :read-only t)); Set of tools currently draining
```

### 4.2 Public Function Signatures in `kargu/tools/execution.el`

1. `(kargu-tool-execution-context-create &key app run-id session-id root mode budget-scope policy-revision)`
   - Constructs and validates a `kargu-tool-execution-context`.
   - `root` is canonicalized via `file-truename` and `file-name-as-directory`.
   - `mode` is validated with `kargu-contract-mode-p`.

2. `(kargu-tool-approval-create &key tool-name args root policy-revision environment)`
   - Generates a fresh unconsumed `kargu-tool-approval` token binding arguments, directory, and revisions.

3. `(kargu-tool-approval-claim approval &key tool-name args root policy-revision)`
   - Checks that `(null (kargu-tool-approval-claimed-p approval))`.
   - Checks that all bound attributes match.
   - Sets `(setf (kargu-tool-approval-claimed-p approval) t)`.
   - Returns `(kargu-ok approval)` or `(kargu-err "Approval token invalid or already claimed" :approval-stale)`.

4. `(kargu-tool-gate-execute registry context name raw-args &key callback approval)`
   - Main entry point for tool execution.
   - Returns a `kargu-async-task` handle.
   - Asynchronously runs the 13-step pipeline.
   - Callback receives either formatted result string or `(kargu-err message code data)`.

5. `(kargu-tool-gate-execute-sync registry context name raw-args &key approval)`
   - Synchronous boundary adapter for legacy synchronous callers.
   - Executes via the gate and blocks until completion using `accept-process-output` / async pump.
   - Returns result string.

6. `(kargu-tool-execution-drain registry name &key cancel-p callback)`
   - Marks tool `name` as draining.
   - If `cancel-p` is non-nil, cancels all active tasks for `name`.
   - When all active tasks complete, unregisters `name` and invokes optional `callback`.

7. `(kargu-tool-execution-active-task-count registry name)`
   - Returns the number of currently in-flight async tasks for canonical tool `name`.

8. `(kargu-tool-execution-redact text)`
   - Sanitizes `text` by replacing API keys, bearer tokens, and secrets with `[REDACTED]`.

---

## 5. Concrete Code Implementation Blueprints for Worker D

### 5.1 Proposed `kargu/tools/registry.el` Updates

```elisp
;; In kargu/tools/registry.el:

(cl-defstruct (kargu-tool-registry (:constructor kargu-tool-registry-create ()))
  "Owned registry of canonical definitions and flattened alias names."
  (entries (make-hash-table :test #'equal) :read-only t)
  (revision 0)
  (draining (make-hash-table :test #'equal) :read-only t))

(defun kargu-tool-registry-revision (registry)
  "Return the monotonic revision counter of REGISTRY."
  (kargu-tool-registry--assert registry)
  (kargu-tool-registry-revision registry))

(defun kargu-tool-registry-mark-draining (registry name)
  "Mark NAME as draining in REGISTRY."
  (kargu-tool-registry--assert registry)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p name)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (puthash canonical t (kargu-tool-registry-draining registry))))

(defun kargu-tool-registry-draining-p (registry name)
  "Return non-nil if NAME or its canonical tool is marked draining in REGISTRY."
  (kargu-tool-registry--assert registry)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (gethash canonical (kargu-tool-registry-draining registry))))

(defun kargu-tool-registry-clear-draining (registry name)
  "Clear draining mark for NAME in REGISTRY."
  (kargu-tool-registry--assert registry)
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (remhash canonical (kargu-tool-registry-draining registry))))
```
Every mutation (`register`, `set-policy`, `alias`, `remove`) increments `(cl-incf (kargu-tool-registry-revision registry))`.

### 5.2 Implementation of `kargu/tools/execution.el`

```elisp
;;; execution.el --- Unified tool execution gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:
;;
;; Single gate for tool execution, parameter schema validation, mode check,
;; single-use approval verification, output budgeting, and async task tracking.
;; (Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/assert)
(require 'kargu/contract/types)
(require 'kargu/contract/result)
(require 'kargu/async)
(require 'kargu/json)
(require 'kargu/tools/registry)
(require 'kargu/application/budget)
(require 'kargu/permission/guards)
(require 'kargu/permission/policy)

;;; Active execution tracking table ---------------------------------------

(defvar kargu-tool-execution--active-tasks (make-hash-table :test #'equal)
  "Map of canonical tool name -> list of active kargu-async-task objects.")

(defun kargu-tool-execution-active-task-count (registry name)
  "Return number of running tasks for NAME in REGISTRY."
  (let ((canonical (kargu-tool-registry-canonical-name registry name)))
    (length (gethash canonical kargu-tool-execution--active-tasks))))

(defun kargu-tool-execution--track-task (name task)
  "Track TASK under canonical tool NAME."
  (let ((existing (gethash name kargu-tool-execution--active-tasks)))
    (puthash name (cons task existing) kargu-tool-execution--active-tasks)))

(defun kargu-tool-execution--untrack-task (name task)
  "Untrack TASK under canonical tool NAME."
  (let* ((existing (gethash name kargu-tool-execution--active-tasks))
         (updated (delq task existing)))
    (if updated
        (puthash name updated kargu-tool-execution--active-tasks)
      (remhash name kargu-tool-execution--active-tasks))))

;;; Context & Approval structs --------------------------------------------

(cl-defstruct (kargu-tool-execution-context
               (:constructor kargu-tool-execution-context--create))
  "Context passed to tool execution gate."
  (context-id (format "exec-%s" (kargu-random-uuid)) :read-only t)
  (app nil :read-only t)
  (run-id nil :read-only t)
  (session-id nil :read-only t)
  (root default-directory :read-only t)
  (mode 'agent :read-only t)
  (budget-scope nil :read-only t)
  (policy-revision 0 :read-only t))

(cl-defun kargu-tool-execution-context-create
    (&key app run-id session-id root (mode 'agent) budget-scope (policy-revision 0))
  "Construct a validated `kargu-tool-execution-context'."
  (let ((effective-root (file-name-as-directory
                         (file-truename (or root (kargu-permission-project-root))))))
    (kargu-contract-assert #'kargu-contract-mode-p mode
                           "Invalid mode: %S" mode)
    (when budget-scope
      (kargu-contract-assert #'kargu-run-budget-p budget-scope
                             "Invalid budget: %S" budget-scope))
    (kargu-tool-execution-context--create
     :app app
     :run-id run-id
     :session-id session-id
     :root effective-root
     :mode mode
     :budget-scope budget-scope
     :policy-revision policy-revision)))

(cl-defstruct (kargu-tool-approval
               (:constructor kargu-tool-approval--create))
  "Single-use captured approval token for guarded execution."
  (token-id (format "appr-%s" (kargu-random-uuid)) :read-only t)
  (tool-name nil :read-only t)
  (args-hash nil :read-only t)
  (root nil :read-only t)
  (policy-revision 0 :read-only t)
  (environment-hash nil :read-only t)
  (claimed-p nil))

(defun kargu-tool-approval--hash-args (args)
  "Compute deterministic SHA256 hash of ARGS."
  (secure-hash 'sha256 (format "%S" args)))

(defun kargu-tool-approval--hash-env ()
  "Compute deterministic SHA256 hash of current `process-environment'."
  (secure-hash 'sha256 (format "%S" (sort (copy-sequence process-environment) #'string<))))

(cl-defun kargu-tool-approval-create
    (&key tool-name args root (policy-revision 0))
  "Create an unconsumed `kargu-tool-approval' token."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p tool-name)
  (kargu-tool-approval--create
   :tool-name tool-name
   :args-hash (kargu-tool-approval--hash-args args)
   :root (file-name-as-directory (file-truename (or root default-directory)))
   :policy-revision policy-revision
   :environment-hash (kargu-tool-approval--hash-env)
   :claimed-p nil))

(defun kargu-tool-approval-claim (approval &key tool-name args root policy-revision)
  "Attempt to claim single-use APPROVAL token against current execution properties.
Returns (kargu-ok approval) on valid first claim, or (kargu-err ... :approval-stale)."
  (unless (kargu-tool-approval-p approval)
    (cl-return-from kargu-tool-approval-claim
      (kargu-err "Invalid approval structure" :invalid-approval)))
  (when (kargu-tool-approval-claimed-p approval)
    (cl-return-from kargu-tool-approval-claim
      (kargu-err "Approval token has already been claimed (replay rejected)" :approval-stale)))
  (let ((cur-args-hash (kargu-tool-approval--hash-args args))
        (cur-root (file-name-as-directory (file-truename (or root default-directory)))))
    (unless (equal (kargu-tool-approval-tool-name approval) tool-name)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval tool name mismatch" :approval-mismatch)))
    (unless (equal (kargu-tool-approval-args-hash approval) cur-args-hash)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval arguments hash mismatch" :approval-mismatch)))
    (unless (equal (kargu-tool-approval-root approval) cur-root)
      (cl-return-from kargu-tool-approval-claim
        (kargu-err "Approval directory root mismatch" :approval-mismatch)))
    (when policy-revision
      (unless (eql (kargu-tool-approval-policy-revision approval) policy-revision)
        (cl-return-from kargu-tool-approval-claim
          (kargu-err "Approval policy revision mismatch" :approval-mismatch))))
    (setf (kargu-tool-approval-claimed-p approval) t)
    (kargu-ok approval)))

;;; Output Redaction -------------------------------------------------------

(defconst kargu-tool-execution--secret-patterns
  '(;; Bearer tokens
    ("Bearer[ \t]+[A-Za-z0-9_\\-\\.]+" . "Bearer [REDACTED]")
    ;; Standard OpenAI/Anthropic/generic API keys
    ("\\(sk-[A-Za-z0-9]{20,}\\)" . "[REDACTED-KEY]")
    ;; Key/secret fields in key-value pairs
    ("\\(\\(?:api[_-]?key\\|secret\\|token\\|password\\|auth\\)[\"']?[ \t]*[:=][ \t]*[\"']?\\)\\([A-Za-z0-9_\\-\\./+=]{8,}\\)"
     . "\\1[REDACTED]"))
  "Regex patterns and replacements for secret redaction in tool output.")

(defun kargu-tool-execution-redact (text)
  "Redact secrets and sensitive tokens from TEXT before model/log presentation."
  (if (not (stringp text))
      text
    (let ((result text))
      (if (fboundp 'kargu-redact-string)
          (funcall 'kargu-redact-string result)
        (save-match-data
          (dolist (pair kargu-tool-execution--secret-patterns result)
            (setq result (replace-regexp-in-string (car pair) (cdr pair) result t))))))))

;;; Execution Gate Pipeline ------------------------------------------------

(defconst kargu-tool-execution--mutating-tools
  '("edit_file" "write_file" "apply_patch" "replace_symbol"
    "bash" "shell" "git_commit" "git_checkout" "git_reset")
  "Tools that perform mutations and require agent mode.")

(defun kargu-tool-execution--mutating-tool-p (name)
  "Return non-nil if canonical NAME represents a mutating tool."
  (member name kargu-tool-execution--mutating-tools))

(defun kargu-tool-execution--validate-gate
    (registry context name raw-args)
  "Validate pipeline steps 1-6 for tool NAME with RAW-ARGS in CONTEXT.
Returns (kargu-ok (list canonical-name definition decoded-args)) or (kargu-err ...)."
  ;; 1. Check registry & context
  (unless (kargu-tool-registry-p registry)
    (cl-return-from kargu-tool-execution--validate-gate
      (kargu-err "Invalid registry handle" :invalid-registry)))
  (unless (kargu-tool-execution-context-p context)
    (cl-return-from kargu-tool-execution--validate-gate
      (kargu-err "Invalid execution context handle" :invalid-context)))
  ;; 2. Canonical resolution
  (let ((definition (kargu-tool-registry-find registry name)))
    (unless definition
      (cl-return-from kargu-tool-execution--validate-gate
        (kargu-err (format "ERROR: no such tool: %s" name) :no-such-tool (list :name name))))
    (let ((canonical (kargu-tool-definition-name definition)))
      (when (kargu-tool-registry-draining-p registry canonical)
        (cl-return-from kargu-tool-execution--validate-gate
          (kargu-err (format "ERROR: tool %s is currently draining/unloading" name) :tool-draining)))
      ;; 3. Mode Check
      (let* ((policy (kargu-tool-definition-policy definition))
             (modes (and policy (plist-get policy :modes)))
             (cur-mode (kargu-tool-execution-context-mode context)))
        (when (and modes (not (memq cur-mode modes)))
          (cl-return-from kargu-tool-execution--validate-gate
            (kargu-err (format "ERROR: Tool %s is unavailable in %s mode." name cur-mode)
                       :mode-forbidden (list :tool name :mode cur-mode))))
        (when (and (kargu-tool-execution--mutating-tool-p canonical)
                   (memq cur-mode '(ask plan)))
          (cl-return-from kargu-tool-execution--validate-gate
            (kargu-err (format "ERROR: Mutating tool %s is forbidden in %s mode." name cur-mode)
                       :mode-forbidden (list :tool name :mode cur-mode))))
        ;; 4. Availability Check
        (when-let* ((avail-fn (and policy (plist-get policy :available-p))))
          (when-let* ((refusal (funcall avail-fn)))
            (cl-return-from kargu-tool-execution--validate-gate
              (kargu-err (if (stringp refusal) refusal (format "ERROR: tool %s unavailable" name))
                         :tool-unavailable (list :tool name :refusal refusal)))))
        ;; 5. Budget Pre-Check
        (when-let* ((budget (kargu-tool-execution-context-budget-scope context)))
          (unless (kargu-budget-live-p budget)
            (cl-return-from kargu-tool-execution--validate-gate
              (kargu-err "ERROR: Run budget exhausted before tool execution"
                         :budget-exhausted (list :reason (kargu-run-budget-status budget))))))
        ;; 6. Decode & Validate Parameters
        (let ((decoded (kargu--decode-tool-arguments raw-args)))
          (when (eq decoded :invalid)
            (cl-return-from kargu-tool-execution--validate-gate
              (kargu-err (format "ERROR: the arguments of tool %s are not a valid JSON object; send one JSON object." name)
                         :invalid-arguments (list :raw raw-args))))
          (kargu-ok (list canonical definition decoded))))))))

(cl-defun kargu-tool-gate-execute
    (registry context name raw-args &key callback approval)
  "Execute tool NAME with RAW-ARGS through the unified gate.
Passes REGISTRY, CONTEXT, and optional APPROVAL token.
DELIVERY GUARANTEE: CALLBACK is invoked exactly once with result string.
Returns a `kargu-async-task' handle."
  (let* ((task (kargu-async-start
                (lambda (val err)
                  (let ((out (if err (format "ERROR: %s" err) val)))
                    (when callback
                      (funcall callback out))))))
         (gate-check (kargu-tool-execution--validate-gate registry context name raw-args)))
    (if (kargu-err-p gate-check)
        ;; Pre-execution gate failure
        (kargu-async-finish task nil (kargu-result-err-message gate-check))
      (let* ((valid-data (kargu-result-value gate-check))
             (canonical (nth 0 valid-data))
             (definition (nth 1 valid-data))
             (args (nth 2 valid-data))
             (policy (kargu-tool-definition-policy definition))
             (executor (kargu-tool-definition-executor definition))
             (budget (kargu-tool-execution-context-budget-scope context))
             (root (kargu-tool-execution-context-root context)))

        ;; 7. Single-Use Captured Approval Check
        (let ((needs-appr (or (and policy (plist-get policy :needs-approval-p))
                              (and (equal canonical "bash") kargu-permission-confirm-bash))))
          (if (and needs-appr (not approval))
              ;; Needs approval, but no token passed -> Request dynamically
              (kargu-permission-request-approval-async
               (format "%s %S" canonical args) root nil
               (kargu-async-wrap
                task
                (lambda (approved)
                  (if (not approved)
                      (kargu-async-finish task nil "Command was not approved by the user")
                    ;; Approved -> capture token & proceed
                    (let ((token (kargu-tool-approval-create
                                  :tool-name canonical :args args :root root
                                  :policy-revision (kargu-tool-execution-context-policy-revision context))))
                      (kargu-tool-approval-claim token :tool-name canonical :args args :root root)
                      (kargu-tool-execution--dispatch-executor
                       task canonical executor args budget root))))))
            (when (and needs-appr approval)
              ;; Token provided -> Claim it
              (let ((claim (kargu-tool-approval-claim
                            approval :tool-name canonical :args args :root root
                            :policy-revision (kargu-tool-execution-context-policy-revision context))))
                (when (kargu-err-p claim)
                  (cl-return-from kargu-tool-gate-execute
                    (progn (kargu-async-finish task nil (kargu-result-err-message claim)) task)))))
            ;; Proceed to execution dispatch
            (kargu-tool-execution--dispatch-executor
             task canonical executor args budget root)))))
    task))

(defun kargu-tool-execution--dispatch-executor
    (task canonical executor args budget root)
  "Internal helper to track and dispatch EXECUTOR for CANONICAL under TASK."
  ;; 8. Track in active tasks
  (kargu-tool-execution--track-task canonical task)
  (kargu-async-add-cleanup task (lambda () (kargu-tool-execution--untrack-task canonical task)))

  ;; Completion callback passed to async executor
  (let ((on-done
         (kargu-async-wrap
          task
          (lambda (res)
            (let* (;; 9. Format
                   (formatted (kargu--format-tool-result res))
                   ;; 10. Redact
                   (redacted (kargu-tool-execution-redact formatted))
                   ;; 11. Budget Accounting
                   (_ (when budget
                        (let ((est-tokens (max 1 (/ (length redacted) 4))))
                          (kargu-budget-record-tokens budget 0 est-tokens))))
                   ;; 12. Bounding & Truncating
                   (final (kargu-tool-execution--truncate-for-model redacted root)))
              (kargu-async-finish task final))))))
    (funcall
     (kargu-async-wrap
      task
      (lambda ()
        (condition-case-unless-debug err
            (if (kargu--executor-async-p executor)
                (let ((ret (funcall executor args on-done)))
                  (when (and (stringp ret) (string-prefix-p "ERROR:" ret))
                    (funcall on-done ret)))
              (funcall on-done (funcall executor args)))
          (error
           (funcall on-done (format "ERROR: tool %s failed: %s"
                                    canonical (error-message-string err))))))))))

;;; Output Truncation & Archive Helpers ------------------------------------

(defun kargu-tool-execution--truncate-for-model (string root)
  "Truncate STRING to `kargu-tool-output-limit' and archive excess under ROOT."
  (let ((limit (if (boundp 'kargu-tool-output-limit) kargu-tool-output-limit 30000)))
    (if (and (natnump limit) (> (length string) limit))
        (let* ((omitted (- (length string) limit))
               (buf-name (kargu-tool-execution--preserve-output string root)))
          (concat (substring string 0 limit)
                  (format "\n... [Output truncated: omitted %d chars. %s]"
                          omitted
                          (if buf-name
                              (format "Preserved in buffer '%s'." buf-name)
                            "Output not archived."))))
      string)))

(defun kargu-tool-execution--preserve-output (string root)
  "Archive STRING in project-owned buffer under ROOT within quotas."
  (when (and (> kargu-tool-output-archive-max-buffers 0)
             (> kargu-tool-output-archive-max-chars 0))
    (let ((chars (min (length string) kargu-tool-output-archive-max-chars)))
      (kargu--prune-tool-output chars)
      (let ((buffer (generate-new-buffer
                     (format "*kargu-output-%d*" (cl-incf kargu--truncated-counter)))))
        (with-current-buffer buffer
          (insert (substring string 0 chars))
          (setq-local kargu--tool-output-root root
                      kargu--tool-output-tick (buffer-chars-modified-tick)
                      buffer-offer-save nil
                      buffer-read-only t)
          (set-buffer-modified-p nil))
        (setq kargu--tool-output-archive (nconc kargu--tool-output-archive (list buffer)))
        (buffer-name buffer)))))

;;; Sync Boundary Adapter --------------------------------------------------

(cl-defun kargu-tool-gate-execute-sync
    (registry context name raw-args &key approval)
  "Synchronous boundary adapter for `kargu-tool-gate-execute'."
  (let (result (done nil))
    (kargu-tool-gate-execute
     registry context name raw-args
     :approval approval
     :callback (lambda (res)
                 (setq result res
                       done t)))
    (let ((deadline (+ (float-time) 10.0)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    (or result "ERROR: tool execution timed out synchronously")))

;;; Draining & Unload Lifecycle --------------------------------------------

(cl-defun kargu-tool-execution-drain
    (registry name &key cancel-p callback)
  "Safely drain active tasks for NAME in REGISTRY before unload.
If CANCEL-P is non-nil, cancels active tasks.  Calls CALLBACK once drained."
  (let* ((canonical (kargu-tool-registry-canonical-name registry name))
         (active (gethash canonical kargu-tool-execution--active-tasks)))
    (kargu-tool-registry-mark-draining registry canonical)
    (if (null active)
        (progn
          (kargu-tool-registry-remove registry canonical)
          (when callback (funcall callback t))
          t)
      (when cancel-p
        (dolist (task active)
          (kargu-async-cancel task)))
      (let ((poller nil))
        (setq poller
              (run-with-timer
               0.05 0.05
               (lambda ()
                 (when (zerop (kargu-tool-execution-active-task-count registry canonical))
                   (cancel-timer poller)
                   (kargu-tool-registry-remove registry canonical)
                   (when callback (funcall callback t))))))))))

(provide 'kargu/tools/execution)
;;; execution.el ends here
```

### 5.3 Adapter Update in `kargu/api/tools.el`

Update `kargu-execute-tool` in `kargu/api/tools.el` to delegate through the gate:

```elisp
;; In kargu/api/tools.el:
(require 'kargu/tools/execution)

(defun kargu-execute-tool (name arguments &optional callback)
  "Run tool NAME with ARGUMENTS; ALWAYS return a result string or invoke CALLBACK.
Delegates to `kargu-tool-gate-execute' via the single execution gate."
  (let* ((root (kargu-permission-project-root))
         (mode (if (fboundp 'kargu-state-mode) (kargu-state-mode) 'agent))
         (budget (and (bound-and-true-p kargu--loop-run)
                      (plist-get kargu--loop-run :budget)))
         (context (kargu-tool-execution-context-create
                   :root root
                   :mode mode
                   :budget-scope budget
                   :policy-revision (kargu-tool-registry-revision kargu--tool-registry))))
    (if callback
        (kargu-tool-gate-execute
         kargu--tool-registry context name arguments :callback callback)
      (kargu-tool-gate-execute-sync
       kargu--tool-registry context name arguments))))
```

---

## 6. Contract Test Suite Design: `tests/test-tool-execution-contract.el`

Worker D must implement `tests/test-tool-execution-contract.el` with tests covering:
1. Canonical tool execution and alias resolution equivalence.
2. Alias read-only bypass prevention (mutating tool through alias blocked in plan/ask mode).
3. Mode gating enforcement (`agent`, `plan`, `ask`).
4. Schema validation and malformed JSON parameter rejection.
5. Availability policy refusal (`:available-p`).
6. Synchronous and asynchronous executor support.
7. Early completion (executor calls `on-done` synchronously inside async wrapper).
8. Duplicate finish protection (executor calling `on-done` twice delivers once).
9. Late execution rejection (callback invoked after cancellation is dropped).
10. Observer error isolation (failing observer or callback does not corrupt gate).
11. Single-use approval token consumption (`claimed-p` prevents replay).
12. Approval token binding verification (mismatched root, tool, or args hash rejects).
13. Absence of confirmation in batch mode defaults to rejection.
14. Output budgeting: tokens recorded to `kargu-run-budget`.
15. Output budgeting: pre-check halts on exhausted budget.
16. Secret redaction before storage and presentation.
17. Truncation bounding and project-owned archive eviction.
18. Safe draining: active task count tracked and cancellation on unregister.
19. Consumer immutability: definition parameters not mutated by gate callers.

---

## 7. Formal Verification & TLA+ Analysis

### 7.1 `proof/KarguApproval.tla` & `ApprovalMC.tla`
- Model verifies:
  1. `Init`: captured request in `phase = "approval"`.
  2. `Change(f)`: any environment or context mutation sets `current[f] = FALSE`.
  3. `Approve`: transitions to `executing` ONLY if all `AuthorityFields` are unmodified.
  4. Single claim: `starts' = starts + 1` with invariant `starts \in 0..1`.
  5. `Safety_Authority`: starts > 0 implies all authority fields were valid at admission.
  6. `Safety_ClosedResources`: closed phase frees all allocated resources.
  7. `Safety_ResultAfterClaim`: terminal delivery occurs only once closed.
- TLC check passes completely: 8,194 generated states, 1,536 distinct states, 0 errors.

### 7.2 `proof/KarguTools.tla`
- Defines mode gating:
  - `MutatingModes == {"agent"}`
  - `GateToolAllowed(name, mode)`
  - `GateToolError(name, mode)`
  - Doom loop detection: `DoomLoopDetected(sigs, sig)`
- Verified through `MC.tla` simulation and full scans.
- Unified gate adheres directly to `GateToolAllowed` and `MutatingModes`.

---

## 8. Migration Plan & Steps for Worker D

1. **Step 1: Registry Enhancements (`kargu/tools/registry.el`)**
   - Add `revision` integer and `draining` hash-table to `kargu-tool-registry`.
   - Add `kargu-tool-registry-revision`, `kargu-tool-registry-mark-draining`, `kargu-tool-registry-draining-p`.
   - Increment revision on all mutations.

2. **Step 2: Unified Gate Implementation (`kargu/tools/execution.el`)**
   - Create `kargu/tools/execution.el` with context struct, approval struct, redaction, and `kargu-tool-gate-execute`.
   - Provide `kargu-tool-gate-execute-sync` boundary adapter.
   - Implement active task tracking and `kargu-tool-execution-drain`.

3. **Step 3: Facade Delegation (`kargu/api/tools.el`)**
   - Require `kargu/tools/execution`.
   - Update `kargu-execute-tool` to delegate to `kargu-tool-gate-execute`.

4. **Step 4: Contract Test Suite (`tests/test-tool-execution-contract.el`)**
   - Implement 19 test cases.
   - Verify 100% pass rate.

5. **Step 5: Verification & Hygiene**
   - Run full ERT test suite (1000+ tests).
   - Byte-compile with `byte-compile-error-on-warn t`.
   - Run `proof/run_tlc.sh --approval`.
   - Clean up any temporary `.elc` files.
