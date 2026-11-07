# Wave 2 Iteration 2 Remediation Report: Package D (Unified Tool Execution Gate & Registry)

**Agent:** `explorer_wave2_it2_1`  
**Working Directory:** `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_it2_1`  
**Parent Conversation ID:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T04:24:30Z  
**Verdict:** **REMEDIATION_READY**

---

## 1. Executive Summary

In response to the Critical challenge issued by Challenger 1 (`challenger_wave2_1`, `REQUEST_CHANGES`), this remediation analysis investigates, reproduces, resolves, and verifies all 3 reported defects in Package D:
1. **Defect 1 (Critical): Mode Gating Bypass at Tool Execution Gate**: Production mutating tools (`edit_file`, `bash`, `git_commit`) lacking explicit `:policy '(:modes ...)` bypassed gate mode validation and allowed disk modification in `ask` and `plan` modes when the session state was `agent`.
2. **Defect 2 (Critical): Single-Use Approval Token Replay on General Tools**: In `kargu-tool-gate-execute`, token claiming was guarded by `(and needs-appr approval)`. For any tool where `needs-appr` evaluated to `nil` (all non-bash tools), passed approval tokens were never claimed (`claimed-p` remained `nil`), permitting indefinite replay.
3. **Defect 3 (High): Tool Policy Schema Rejection of `:needs-approval-p`**: `kargu-tool-registry--policy-p` strictly restricted policy keys to `(:modes :available-p)` and threw a contract assertion failure when `:needs-approval-p` was supplied.

All three defects were empirically reproduced in isolated batch Emacs runs, precisely fixed, and verified. Following remediation:
- **1052 of 1052 ERT tests pass** (1049 baseline + 3 new contract tests) with 0 failures and 0 errors.
- **Zero byte-compilation warnings** with `(setq byte-compile-error-on-warn t)` on all modified and test files.
- **Zero checkdoc warnings** on all production and test files.
- **Exhaustive TLC model checks** pass with 0 errors (`--approval`, `--mode`, `--budget`, `--process`, `--transport`).
- Zero repository hygiene violations (no `.elc` files, `skills.md` and `.gitignore` completely untouched).

---

## 2. In-Depth Root Cause Analysis & Empirical Evidence

### Defect 1: Mode Gating Bypass (`kargu/tools/execution.el`)

- **Root Cause**:
  `kargu/tools/execution.el` declared `(defvar kargu-loop-mutating-tools)` at line 32, but `kargu-tool-execution--validate-gate` at line 371 only checked:
  ```elisp
  (let* ((policy (kargu-tool-definition-policy definition))
         (modes (and policy (plist-get policy :modes)))
         (cur-mode (kargu-tool-execution-context-mode context)))
    (when (and modes (not (memq cur-mode modes)))
      (cl-return-from kargu-tool-execution--validate-gate ...)))
  ```
  Because production tools (`edit_file`, `write_file`, `bash`, `git_commit`) are registered without `:policy` (or with `policy = nil`), `modes` evaluated to `nil`. Consequently, `kargu-tool-execution--validate-gate` returned `(kargu-ok ...)` regardless of whether `context` had `:mode 'ask'` or `:mode 'plan'`.
  When executing `edit_file`, execution fell back to `kargu-diff--edit-file-tool`, which queried `(kargu-state-mode)` from the global session rather than the context mode. If the global session was `agent`, disk mutations were written to disk in `ask` and `plan` contexts.
- **Empirical Reproduction Observation**:
  Executing `edit_file` in an explicit `ask` context with session mode set to `agent`:
  - Result: `"APPLIED: the change to ... has been applied and the file is saved."`
  - Disk Content: `"MUTATED IN ASK MODE!\n"`.
- **Remediation**:
  In `kargu-tool-execution--validate-gate`, enforce that if a tool's canonical name is a member of `kargu-loop-mutating-tools` (with fallback list if `kargu/loop` is not yet loaded), it is disallowed whenever `cur-mode` is not `'agent`.

### Defect 2: Approval Token Single-Use Claim Skipped (`kargu/tools/execution.el`)

- **Root Cause**:
  In `kargu-tool-gate-execute`:
  ```elisp
  (let ((needs-appr
         (or (and policy (plist-get policy :needs-approval-p))
             (and (equal canonical "bash")
                  (bound-and-true-p kargu-permission-confirm-bash)))))
    (if (and needs-appr (not approval))
        ...
      (when (and needs-appr approval)
        (let ((claim (kargu-tool-approval-claim ...))))))
  ```
  If a caller passed `:approval token` for any tool other than `"bash"` (or tools without `:needs-approval-p`), `needs-appr` evaluated to `nil`. The token claim was skipped completely. `claimed-p` stayed `nil`, allowing identical tokens to be submitted repeatedly without encountering `:approval-stale`.
- **Empirical Reproduction Observation**:
  - Initial token `claimed-p`: `nil`.
  - Exec 1: `claimed-p` = `nil` (`executed=1`).
  - Exec 2 (Replay): `claimed-p` = `nil` (`executed=2`).
- **Remediation**:
  Restructure the approval stage in `kargu-tool-gate-execute` into a `cond`:
  1. `approval`: ALWAYS verify and claim the token via `kargu-tool-approval-claim` regardless of `needs-appr`. If claiming returns an error (such as `:approval-stale` or `:approval-mismatch`), terminate the task with that error.
  2. `needs-appr`: If no token was provided but approval is needed, request dynamic approval.
  3. Otherwise: Dispatch to executor directly.

### Defect 3: Inconsistent Policy Contract Rejects `:needs-approval-p` (`kargu/tools/registry.el`)

- **Root Cause**:
  `kargu-tool-registry--policy-p` allowed only `:modes` and `:available-p`:
  ```elisp
  (cl-loop for (key _value) on policy by #'cddr
           always (memq key '(:modes :available-p)))
  ```
  Attempting to declare `:policy '(:modes (agent) :needs-approval-p t)` triggered an assertion failure on registration.
- **Empirical Reproduction Observation**:
  Calling `kargu-tool-registry-register` with `:policy '(:modes (agent) :needs-approval-p t)` resulted in:
  `Contract violation: (:modes (agent) :needs-approval-p t) does not satisfy kargu-tool-registry--policy-p`.
- **Remediation**:
  Add `:needs-approval-p` to allowed keys in `kargu-tool-registry--policy-p` and enforce `(booleanp (plist-get policy :needs-approval-p))`.

---

## 3. Formulated Code Changes (Before / After)

### File 1: `kargu/tools/registry.el`

#### Change 1.1: Allow `:needs-approval-p` in `kargu-tool-registry--policy-p`

**Target File:** `kargu/tools/registry.el`  
**Lines:** 57–66

**Before:**
```elisp
(defun kargu-tool-registry--policy-p (policy)
  "Return non-nil when POLICY describes supported execution gates."
  (and (proper-list-p policy)
       (cl-evenp (length policy))
       (cl-loop for (key _value) on policy by #'cddr
                always (memq key '(:modes :available-p)))
       (proper-list-p (plist-get policy :modes))
       (seq-every-p #'kargu-contract-mode-p (plist-get policy :modes))
       (kargu-contract-callback-p (plist-get policy :available-p))))
```

**After:**
```elisp
(defun kargu-tool-registry--policy-p (policy)
  "Return non-nil when POLICY describes supported execution gates."
  (and (proper-list-p policy)
       (cl-evenp (length policy))
       (cl-loop for (key _value) on policy by #'cddr
                always (memq key '(:modes :available-p :needs-approval-p)))
       (proper-list-p (plist-get policy :modes))
       (seq-every-p #'kargu-contract-mode-p (plist-get policy :modes))
       (kargu-contract-callback-p (plist-get policy :available-p))
       (booleanp (plist-get policy :needs-approval-p))))
```

---

### File 2: `kargu/tools/execution.el`

#### Change 2.1: Enforce Mode Gating for Mutating Tools in `kargu-tool-execution--validate-gate`

**Target File:** `kargu/tools/execution.el`  
**Lines:** 347–380

**Before:**
```elisp
(cl-defun kargu-tool-execution--validate-gate
    (registry context name raw-args)
  "Validate pipeline steps 1-6 for tool NAME with RAW-ARGS in CONTEXT.
Returns (kargu-ok (list canonical-name definition decoded-args))
or (kargu-err ...)."
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
        (kargu-err (format "ERROR: no such tool: %s" name)
                   :no-such-tool (list :name name))))
    (let ((canonical (kargu-tool-definition-name definition)))
      (when (kargu-tool-registry-draining-p registry canonical)
        (cl-return-from kargu-tool-execution--validate-gate
          (kargu-err (format "ERROR: tool %s is currently draining/unloading"
                             name)
                     :tool-draining (list :name name))))
      ;; 3. Mode Check
      (let* ((policy (kargu-tool-definition-policy definition))
             (modes (and policy (plist-get policy :modes)))
             (cur-mode (kargu-tool-execution-context-mode context)))
        (when (and modes (not (memq cur-mode modes)))
          (cl-return-from kargu-tool-execution--validate-gate
            (kargu-err (format "ERROR: Tool %s is unavailable in %s mode."
                               name cur-mode)
                       :mode-forbidden (list :tool name :mode cur-mode))))
```

**After:**
```elisp
(cl-defun kargu-tool-execution--validate-gate
    (registry context name raw-args)
  "Validate pipeline stages 1-6 for tool NAME with RAW-ARGS in CONTEXT.
Validate against REGISTRY.
Return (kargu-ok (list canonical-name definition decoded-args))
or (kargu-err ...)."
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
        (kargu-err (format "ERROR: no such tool: %s" name)
                   :no-such-tool (list :name name))))
    (let ((canonical (kargu-tool-definition-name definition)))
      (when (kargu-tool-registry-draining-p registry canonical)
        (cl-return-from kargu-tool-execution--validate-gate
          (kargu-err (format "ERROR: tool %s is currently draining/unloading"
                             name)
                     :tool-draining (list :name name))))
      ;; 3. Mode Check
      (let* ((policy (kargu-tool-definition-policy definition))
             (modes (and policy (plist-get policy :modes)))
             (cur-mode (kargu-tool-execution-context-mode context))
             (mutating-tools (if (boundp 'kargu-loop-mutating-tools)
                                 kargu-loop-mutating-tools
                               '("edit_file" "write_file" "edit" "write"
                                 "apply_patch" "patch" "bash"
                                 "edit_symbol" "edit_with_lsp" "edit_by_symbol"
                                 "git_commit" "git_stage" "git_unstage"
                                 "git_branch" "git_stash"))))
        (when (or (and modes (not (memq cur-mode modes)))
                  (and (or (member canonical mutating-tools)
                           (member name mutating-tools))
                       (not (eq cur-mode 'agent))))
          (cl-return-from kargu-tool-execution--validate-gate
            (kargu-err (format "ERROR: Tool %s is unavailable in %s mode."
                               name cur-mode)
                       :mode-forbidden (list :tool name :mode cur-mode))))
```

#### Change 2.2: Unconditional Approval Verification & Claim in `kargu-tool-gate-execute`

**Target File:** `kargu/tools/execution.el`  
**Lines:** 454–492

**Before:**
```elisp
        ;; 7. Single-Use Captured Approval Check
        (let ((needs-appr
               (or (and policy (plist-get policy :needs-approval-p))
                   (and (equal canonical "bash")
                        (bound-and-true-p kargu-permission-confirm-bash)))))
          (if (and needs-appr (not approval))
              ;; Needs approval, but no token passed -> Request dynamically
              (kargu-permission-request-approval-async
               (format "%s %S" canonical args) root nil
               (kargu-async-wrap
                task
                (lambda (approved)
                  (if (not approved)
                      (kargu-async-finish
                       task nil "Command was not approved by the user")
                    ;; Approved -> capture token & claim
                    (let ((token (kargu-tool-approval-create
                                  :tool-name canonical :args args :root root
                                  :policy-revision rev)))
                      (kargu-tool-approval-claim token :tool-name canonical
                                                 :args args :root root
                                                 :policy-revision rev)
                      (kargu-tool-execution--dispatch-executor
                       task canonical executor args budget root))))))
            (when (and needs-appr approval)
              ;; Token provided -> Claim it
              (let ((claim (kargu-tool-approval-claim
                            approval :tool-name canonical :args args
                            :root root :policy-revision rev)))
                (when (kargu-err-p claim)
                  (cl-return-from kargu-tool-gate-execute
                    (progn
                      (kargu-async-finish
                       task nil (kargu-result-err-message claim))
                      task)))))
            ;; Proceed to execution dispatch
            (kargu-tool-execution--dispatch-executor
             task canonical executor args budget root)))))
```

**After:**
```elisp
        ;; 7. Single-Use Captured Approval Check
        (let ((needs-appr
               (or (and policy (plist-get policy :needs-approval-p))
                   (and (equal canonical "bash")
                        (bound-and-true-p kargu-permission-confirm-bash)))))
          (cond
           (approval
            ;; Token provided -> ALWAYS verify and claim it
            (let ((claim (kargu-tool-approval-claim
                          approval :tool-name canonical :args args
                          :root root :policy-revision rev)))
              (if (kargu-err-p claim)
                  (kargu-async-finish
                   task nil (kargu-result-err-message claim))
                (kargu-tool-execution--dispatch-executor
                 task canonical executor args budget root))))
           (needs-appr
            ;; Needs approval, but no token passed -> Request dynamically
            (kargu-permission-request-approval-async
             (format "%s %S" canonical args) root nil
             (kargu-async-wrap
              task
              (lambda (approved)
                (if (not approved)
                    (kargu-async-finish
                     task nil "Command was not approved by the user")
                  ;; Approved -> capture token & claim
                  (let ((token (kargu-tool-approval-create
                                :tool-name canonical :args args :root root
                                :policy-revision rev)))
                    (kargu-tool-approval-claim token :tool-name canonical
                                               :args args :root root
                                               :policy-revision rev)
                    (kargu-tool-execution--dispatch-executor
                     task canonical executor args budget root)))))))
           (t
            ;; No approval required or provided -> Proceed to execution dispatch
            (kargu-tool-execution--dispatch-executor
             task canonical executor args budget root))))))
```

---

### File 3: `tests/test-tool-execution-contract.el`

#### Change 3.1: Fix Fixture Docstring for Checkdoc and Add 3 Contract Tests

**Target File:** `tests/test-tool-execution-contract.el`  
**Lines:** 22–24 and 410–495

**Fixture Docstring Adjustment:**
```elisp
(defun kargu-test-tool--make-test-fixture ()
  "Create an isolated registry and execution context for testing."
```

**Added ERT Test Cases (Tests 20, 21, and 22):**
```elisp
;; 20. Mutating tools rejected in ask mode even without explicit policy
(ert-deftest kargu-tool-gate-mutating-tools-rejected-in-ask-mode-test ()
  "Mutating tools without explicit policy are rejected at gate in ask mode."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (ask-ctx (kargu-tool-execution-context-create :root root :mode 'ask))
         (executed nil))
    (kargu-tool-registry-register
     reg :name "edit_file" :description "Edit file"
     :executor (lambda (_) (push "edit_file" executed) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))
    (kargu-tool-registry-register
     reg :name "bash" :description "Bash shell"
     :executor (lambda (_) (push "bash" executed) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (let (res-edit res-bash)
      (kargu-tool-gate-execute reg ask-ctx "edit_file" nil
                               :callback (lambda (r) (setq res-edit r)))
      (kargu-tool-gate-execute reg ask-ctx "bash" nil
                               :callback (lambda (r) (setq res-bash r)))
      (should-not executed)
      (should (string-prefix-p "ERROR:" res-edit))
      (should (string-match-p "unavailable in ask mode" res-edit))
      (should (string-prefix-p "ERROR:" res-bash))
      (should (string-match-p "unavailable in ask mode" res-bash)))))

;; 21. Approval claim and single-use anti-replay on general tools
(ert-deftest kargu-tool-gate-general-tool-approval-claim-and-replay-test ()
  "Approval tokens passed to general tools are claimed and replays fail."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (executed 0)
         res1 res2)
    (kargu-tool-registry-register
     reg :name "guarded_custom_op" :description "Guarded custom tool"
     :executor (lambda (_) (cl-incf executed) "SUCCESS")
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:modes (agent)))

    (let* ((ctx (kargu-tool-execution-context-create
                 :root root :mode 'agent
                 :policy-revision (kargu-tool-registry-revision reg)))
           (args '(("key" . "val")))
           (token (kargu-tool-approval-create
                   :tool-name "guarded_custom_op" :args args :root root
                   :policy-revision (kargu-tool-registry-revision reg))))
      (should-not (kargu-tool-approval-claimed-p token))

      ;; First execution claims token and succeeds
      (kargu-tool-gate-execute reg ctx "guarded_custom_op" args
                               :approval token
                               :callback (lambda (r) (setq res1 r)))
      (should (equal res1 "SUCCESS"))
      (should (= executed 1))
      (should (kargu-tool-approval-claimed-p token))

      ;; Replay execution is rejected with approval error
      (kargu-tool-gate-execute reg ctx "guarded_custom_op" args
                               :approval token
                               :callback (lambda (r) (setq res2 r)))
      (should (= executed 1))
      (should (string-prefix-p "ERROR:" res2))
      (should (string-match-p "already been claimed" res2)))))

;; 22. Tool registry policy schema supports :needs-approval-p
(ert-deftest kargu-tool-registry-policy-needs-approval-p-test ()
  "Tool registry accepts boolean :needs-approval-p in policy schema."
  (let ((reg (kargu-tool-registry-create)))
    (should (equal (kargu-tool-registry-register
                    reg :name "needs_appr_tool" :description "Needs approval"
                    :executor #'ignore
                    :parameters '(("type" . "object") ("properties" . :json-empty-object))
                    :policy '(:modes (agent) :needs-approval-p t))
                   "needs_appr_tool"))
    (should (equal (kargu-tool-registry-register
                    reg :name "no_appr_tool" :description "No approval"
                    :executor #'ignore
                    :parameters '(("type" . "object") ("properties" . :json-empty-object))
                    :policy '(:modes (agent) :needs-approval-p nil))
                   "no_appr_tool"))
    (should-error (kargu-tool-registry-register
                   reg :name "bad_appr_tool" :description "Bad approval"
                   :executor #'ignore
                   :parameters '(("type" . "object") ("properties" . :json-empty-object))
                   :policy '(:modes (agent) :needs-approval-p "invalid"))
                  :type 'error)))
```

---

### File 4: `tests/test-tools.el`

#### Change 4.1: Isolate `kargu-execute-tool-async-bash-test` with `agent` Mode

**Target File:** `tests/test-tools.el`  
**Lines:** 488–496

**Rationale:**
Now that `bash` is properly recognized as a mutating tool and gated in read-only modes (`ask` / `plan`), executing `bash` requires `agent` mode. All other mutating tool tests in `tests/test-tools.el` (e.g., lines 380, 400, 427, 453) explicitly set `(_ (kargu-test-mode 'agent))`. Adding this declaration to `kargu-execute-tool-async-bash-test` aligns it with the rest of the test suite and prevents it from inheriting the default `'ask` mode.

**Before:**
```elisp
(ert-deftest kargu-execute-tool-async-bash-test ()
  "Tool execution delegates to a callback asynchronously for Bash."
  (let* ((kargu-permission-confirm-bash nil)
         (done nil)
         (result nil))
    (kargu-execute-tool "bash" '(("command" . "echo tool_exec_async_test"))
```

**After:**
```elisp
(ert-deftest kargu-execute-tool-async-bash-test ()
  "Tool execution delegates to a callback asynchronously for Bash."
  (let* ((_ (kargu-test-mode 'agent))
         (kargu-permission-confirm-bash nil)
         (done nil)
         (result nil))
    (kargu-execute-tool "bash" '(("command" . "echo tool_exec_async_test"))
```

---

## 4. Verification Evidence & Quality Gates

### 4.1. Full ERT Test Suite (Acceptance Criteria R3)
- **Command:**
  ```bash
  emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
  ```
- **Result:**
  ```
  Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:23:13+0000, 43.959009 sec)
  ```
  Exit code: **0**. Zero failures, zero errors.

### 4.2. Package D Contract Tests specifically
- **Command:**
  ```bash
  emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (load-file "tests/test-tool-execution-contract.el"))' -f ert-run-tests-batch-and-exit
  ```
- **Result:**
  ```
  Ran 22 tests, 22 results as expected, 0 unexpected (2026-10-22 04:15:21+0000, 0.033220 sec)
  ```
  All 22 contract tests pass cleanly.

### 4.3. Byte Compilation under `byte-compile-error-on-warn t`
- **Command:**
  ```bash
  emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f (list "kargu/tools/registry.el" "kargu/tools/execution.el" "tests/test-tool-execution-contract.el" "tests/test-tools.el")) (byte-compile-file f)))'
  find . -name "*.elc" -delete
  ```
- **Result:**
  Exit code: **0**. Zero byte-compile warnings and zero errors across all four files.

### 4.4. Checkdoc Linter
- **Command:**
  ```bash
  emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (require (quote checkdoc)) (dolist (f (list "kargu/tools/registry.el" "kargu/tools/execution.el" "tests/test-tool-execution-contract.el" "tests/test-tools.el")) (checkdoc-file f)))'
  ```
- **Result:**
  Exit code: **0**. Zero warnings.

### 4.5. Formal Verification (TLC Models)
- **Commands:**
  ```bash
  bash proof/run_tlc.sh --approval
  bash proof/run_tlc.sh --mode
  bash proof/run_tlc.sh --budget
  bash proof/run_tlc.sh --process
  bash proof/run_tlc.sh --transport
  ```
- **Results:**
  - `ApprovalMC.tla` (`KarguApproval`): 8,194 states generated, 1,536 distinct states checked. 0 errors.
  - `ModeMC.tla` (`KarguMode`): 20,179 states generated, 5,958 distinct states checked. 0 errors.
  - `BudgetMC.tla` (`KarguBudget`): 1,591 states generated, 432 distinct states checked. 0 errors.
  - `ProcessMC.tla` (`KarguProcess`): 535 states generated, 179 distinct states checked. 0 errors.
  - `TransportMC.tla` (`KarguTransport`): 1,810 states generated, 693 distinct states checked. 0 errors.

### 4.6. Repository Hygiene
- `git status --porcelain skills.md .gitignore` -> empty (files untouched).
- `find . -name "*.elc"` -> 0 files (no leftover binaries).

---

## 5. Conclusion & Recommendations

The remediation for Package D is complete, verified, and adheres to all contracts and acceptance criteria:
1. Mode gating at the unified gate level prevents any disk modification in `ask` and `plan` modes.
2. Single-use approval token verification and claiming is universally enforced for all tools, eliminating replay vulnerabilities.
3. The tool registry policy schema fully supports `:needs-approval-p`.
4. All 1052 tests pass with zero warnings in compilation, checkdoc, and TLC model checking.

The changes are captured in the working directory files and ready for immediate adoption by the worker and orchestrator.
