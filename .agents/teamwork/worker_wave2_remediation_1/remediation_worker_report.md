# Wave 2 Package D Remediation Worker Report

**Agent:** `worker_wave2_remediation_1`  
**Working Directory:** `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_remediation_1`  
**Parent Conversation ID:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T04:29:45Z  
**Verdict:** **REMEDIATION_VERIFIED_AND_COMPLETE**

---

## 1. Executive Summary

As the Wave 2 Remediation Worker for Package D (Unified Tool Execution Gate & Registry), this report details the complete verification and validation of the remediation changes addressing all 3 defects raised by Challenger 1 (`challenger_wave2_1`, `REQUEST_CHANGES`) and formulated by Explorer Wave 2 Iteration 2 (`explorer_wave2_it2_1`):

1. **Defect 1 (Critical) - Mode Gating Bypass at Tool Execution Gate**:
   - Mutating tools lacking explicit policy bypassed gate checks in `ask` and `plan` modes.
   - **Remediation**: In `kargu/tools/execution.el` (`kargu-tool-execution--validate-gate`), enforced that if a tool canonical name or alias is in `kargu-loop-mutating-tools`, execution is rejected with `:mode-forbidden` unless context mode is `'agent`.
2. **Defect 2 (Critical) - Approval Token Single-Use Claim Skipped on General Tools**:
   - `kargu-tool-gate-execute` previously guarded claiming on `(and needs-appr approval)`, skipping claiming for non-bash tools and allowing token replays.
   - **Remediation**: In `kargu/tools/execution.el` (`kargu-tool-gate-execute`), restructured to unconditional verification and claiming on any passed `:approval` token via `kargu-tool-approval-claim`.
3. **Defect 3 (High) - Policy Schema Rejected `:needs-approval-p`**:
   - `kargu-tool-registry--policy-p` rejected `:needs-approval-p` key.
   - **Remediation**: In `kargu/tools/registry.el` (`kargu-tool-registry--policy-p`), permitted `:needs-approval-p` with boolean type validation.
4. **Test Suite Adaptations & Additions**:
   - In `tests/test-tool-execution-contract.el`: Added Tests 20, 21, and 22 covering all three remediation invariants.
   - In `tests/test-tools.el`: Scoped `kargu-execute-tool-async-bash-test` with `(_ (kargu-test-mode 'agent))` to match test suite conventions for mutating tools.

All 3 Challenger reproduction/verification scripts and all project quality gates have been executed and verified:
- **Challenger Scripts**: All 3 verified with expected results (no disk mutation in ask mode; token claimed and replay rejected; `:needs-approval-p` boolean policy accepted).
- **Full ERT Suite**: **1052 of 1052 tests pass** (0 failures, 0 errors, 44.18s).
- **Byte Compilation**: Zero warnings with `(setq byte-compile-error-on-warn t)` across all 4 modified files.
- **Checkdoc**: Zero warnings across all 4 modified files.
- **Artifact Cleanliness**: Zero `.elc` files remain.
- **Formal Verification**: TLC model checkers pass with 0 errors (`bash proof/run_tlc.sh --approval` and `bash proof/run_tlc.sh --transport`).
- **Repository Hygiene**: `skills.md` and `.gitignore` remain completely untouched and unstaged (`git status --porcelain` empty).

---

## 2. Remediation Implementation Details

### 2.1. `kargu/tools/execution.el`

#### Mode Gating Enforcement (`kargu-tool-execution--validate-gate`):
```elisp
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

#### Unconditional Single-Use Approval Claim (`kargu-tool-gate-execute`):
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

### 2.2. `kargu/tools/registry.el`

#### Policy Schema Allowing `:needs-approval-p` (`kargu-tool-registry--policy-p`):
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

### 2.3. `tests/test-tool-execution-contract.el`

Added three contract test cases:
- Test 20: `kargu-tool-gate-mutating-tools-rejected-in-ask-mode-test` (verifies gate mode rejection on mutating tools lacking explicit policy).
- Test 21: `kargu-tool-gate-general-tool-approval-claim-and-replay-test` (verifies token claim and anti-replay rejection on general tools).
- Test 22: `kargu-tool-registry-policy-needs-approval-p-test` (verifies registry policy validation with boolean `:needs-approval-p` and rejection of invalid values).

### 2.4. `tests/test-tools.el`

Updated `kargu-execute-tool-async-bash-test`:
Scoped with `(_ (kargu-test-mode 'agent))` so the test runs in `agent` mode, adhering to mode gating rules.

---

## 3. Challenger Empirical Verification Scripts & Output

### 3.1. Challenger Script 1: Mode Gating Bypass Check (No Disk Mutation in Ask Mode)

- **Execution Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn
    (require (quote package)) (package-initialize)
    (require (quote kargu)) (require (quote kargu/tools/diff)) (require (quote kargu/tools/execution))
    (kargu-diff-register-tools)
    (setf (kargu-session-mode-value (kargu-session-context)) (quote agent))
    (let* ((reg kargu--tool-registry) (root (file-name-as-directory (expand-file-name default-directory)))
           (ctx-ask (kargu-tool-execution-context-create :mode (quote ask) :root root))
           (temp-file (expand-file-name "temp_test_edit.txt" root)))
      (with-temp-file temp-file (insert "initial\n"))
      (unwind-protect
          (let ((res (kargu-tool-gate-execute-sync reg ctx-ask "edit_file"
                      (list (cons "file_path" temp-file) (cons "old_string" "initial") (cons "new_string" "MUTATED!")))))
            (message "RESULT: %S" res)
            (message "DISK: %S" (with-temp-buffer (insert-file-contents temp-file) (buffer-string))))
        (when (file-exists-p temp-file) (delete-file temp-file)))))'
  ```
- **Observed Output**:
  ```
  RESULT: "ERROR: Tool edit_file is unavailable in ask mode."
  DISK: "initial\n"
  ```
- **Verification Assessment**: **PASS**. Disk file remains unmodified ("initial\n") and execution is blocked at the gate.

### 3.2. Challenger Script 2: General Tool Single-Use Approval Claim & Anti-Replay

- **Execution Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn
    (require (quote package)) (package-initialize)
    (require (quote kargu)) (require (quote kargu/tools/registry)) (require (quote kargu/tools/execution))
    (let* ((reg (kargu-tool-registry-create)) (root (file-name-as-directory (expand-file-name default-directory))) (executed 0))
      (kargu-tool-registry-register reg :name "op" :description "Op"
       :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
       :executor (lambda (args) (cl-incf executed) "OK") :policy (list :modes (quote (agent))))
      (let* ((ctx (kargu-tool-execution-context-create :root root :mode (quote agent) :policy-revision (kargu-tool-registry-revision reg)))
             (args (quote (("k" . "v"))))
             (token (kargu-tool-approval-create :tool-name "op" :args args :root root :policy-revision (kargu-tool-registry-revision reg))))
        (let ((r1 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
          (message "Claimed after exec 1: %S (res=%S)" (kargu-tool-approval-claimed-p token) r1))
        (let ((r2 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
          (message "Claimed after exec 2: %S (executed=%d, res=%S)" (kargu-tool-approval-claimed-p token) executed r2)))))'
  ```
- **Observed Output**:
  ```
  Claimed after exec 1: t (res="OK")
  Claimed after exec 2: t (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)")
  ```
- **Verification Assessment**: **PASS**. Token is claimed (`claimed-p = t`) on the first execution; replay on second execution is rejected without executing the tool (`executed = 1`).

### 3.3. Challenger Script 3: Tool Policy Schema with `:needs-approval-p`

- **Execution Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn
    (require (quote package)) (package-initialize)
    (require (quote kargu)) (require (quote kargu/tools/registry))
    (let ((reg (kargu-tool-registry-create)))
      (let ((res1 (kargu-tool-registry-register
                   reg :name "test_appr_t" :description "Tool needing approval"
                   :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
                   :executor (quote ignore)
                   :policy (quote (:modes (agent) :needs-approval-p t))))
            (res2 (kargu-tool-registry-register
                   reg :name "test_appr_nil" :description "Tool not needing approval"
                   :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
                   :executor (quote ignore)
                   :policy (quote (:modes (agent) :needs-approval-p nil)))))
        (message "Registered with t: %S, with nil: %S" res1 res2)
        (let ((def (kargu-tool-registry-find reg "test_appr_t")))
          (message "Policy retrieved: %S" (kargu-tool-definition-policy def)))
        (condition-case err
            (kargu-tool-registry-register
             reg :name "test_bad" :description "Bad approval"
             :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
             :executor (quote ignore)
             :policy (quote (:modes (agent) :needs-approval-p "invalid")))
          (error (message "Expected rejection of non-boolean: %S" err))))))'
  ```
- **Observed Output**:
  ```
  Registered with t: "test_appr_t", with nil: "test_appr_nil"
  Policy retrieved: (:modes (agent) :needs-approval-p t)
  Expected rejection of non-boolean: (error "Contract violation: (:modes (agent) :needs-approval-p \"invalid\") does not satisfy kargu-tool-registry--policy-p")
  ```
- **Verification Assessment**: **PASS**. Both `t` and `nil` values register successfully, and invalid non-boolean values are rejected by contract assertion.

---

## 4. Verification & Quality Gates

### 4.1. Full ERT Test Suite
- **Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
  ```
- **Output**:
  ```
  Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:28:45+0000, 44.185120 sec)
  ```
- **Exit Code**: `0`.

### 4.2. Byte-Compilation Cleanliness
- **Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn
    (require (quote package)) (package-initialize)
    (setq byte-compile-error-on-warn t)
    (dolist (f (list "kargu/tools/registry.el"
                     "kargu/tools/execution.el"
                     "tests/test-tool-execution-contract.el"
                     "tests/test-tools.el"))
      (byte-compile-file f)))'
  ```
- **Output**:
  ```
  Compiling kargu/tools/registry.el...
  Compiling kargu/tools/execution.el...
  Compiling tests/test-tool-execution-contract.el...
  Compiling tests/test-tools.el...
  ```
- **Exit Code**: `0` (Zero warnings, zero errors).

### 4.3. Checkdoc Cleanliness
- **Command**:
  ```bash
  emacs -Q --batch -L . --eval '(progn
    (require (quote package)) (package-initialize)
    (require (quote checkdoc))
    (dolist (f (list "kargu/tools/registry.el"
                     "kargu/tools/execution.el"
                     "tests/test-tool-execution-contract.el"
                     "tests/test-tools.el"))
      (checkdoc-file f)))'
  ```
- **Output**: Zero `Warning (emacs):` messages. Exit code `0`.

### 4.4. Binary Cleanup
- **Command**:
  ```bash
  find . -name "*.elc" -delete && find . -name "*.elc"
  ```
- **Output**: Empty (0 `.elc` files present in the repository).

### 4.5. Formal Verification (TLA+/TLC Models)
- **Commands & Results**:
  - `bash proof/run_tlc.sh --approval`:
    - Model: `ApprovalMC.tla` (`KarguApproval`)
    - 8,194 states generated, 1,536 distinct states found, 0 errors.
  - `bash proof/run_tlc.sh --transport`:
    - Model: `TransportMC.tla` (`KarguTransport`)
    - 1,810 states generated, 693 distinct states found, 0 errors.

### 4.6. Repository Hygiene
- **Command**:
  ```bash
  git status --porcelain skills.md .gitignore
  ```
- **Output**: Empty. Protected files remain completely untouched and unstaged.

---

## 5. Conclusion

The remediation for Package D is fully implemented, verified, and complete. All challenger failure modes have been demonstrated to be resolved, all 1052 tests pass cleanly, byte-compilation and checkdoc pass with zero warnings, TLC model checks pass without error, and repository hygiene is fully maintained.
