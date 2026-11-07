# Handoff Report: Wave 2 Iteration 2 Forensic Audit

**Agent:** `auditor_wave2_it2_1`  
**Parent Agent:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T04:36:00Z  
**Type:** Hard Handoff (Task Complete)  
**Verdict:** **CLEAN**

---

## 1. Observation

1. **Remediation Code Inspection in `kargu/tools/execution.el`**:
   - Lines 373–390:
     ```elisp
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
                      :mode-forbidden (list :tool name :mode cur-mode)))))
     ```
   - Lines 460–493:
     ```elisp
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
        task canonical executor args budget root)))
     ```

2. **Remediation Code Inspection in `kargu/tools/registry.el`**:
   - Lines 59–67:
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

3. **Challenger Empirical Script 1 Execution (Mode Gating)**:
   - Tool execution gate in `ask` mode context attempting to invoke mutating tool `edit_file`:
     ```
     RESULT: "ERROR: Tool edit_file is unavailable in ask mode."
     DISK: "initial\n"
     ```

4. **Challenger Empirical Script 2 Execution (Approval Claim & Anti-Replay)**:
   - Dual execution of general tool `op` using the same approval token:
     ```
     Claimed after exec 1: t (res="OK")
     Claimed after exec 2: t (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)")
     ```

5. **Challenger Empirical Script 3 Execution (Policy Schema)**:
   - Policy schema registration with `:needs-approval-p`:
     ```
     Registered with t: "test_appr_t", with nil: "test_appr_nil"
     Policy retrieved: (:modes (agent) :needs-approval-p t)
     Expected rejection of non-boolean: (error "Contract violation: (:modes (agent) :needs-approval-p \"invalid\") does not satisfy kargu-tool-registry--policy-p")
     ```

6. **Package D Contract Tests (`tests/test-tool-execution-contract.el`)**:
   - Command:
     `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (load-file "tests/test-tool-execution-contract.el"))' -f ert-run-tests-batch-and-exit`
   - Output:
     `Ran 22 tests, 22 results as expected, 0 unexpected (2026-10-22 04:33:28+0000, 0.035019 sec)`
   - Exit Code: `0`.

7. **Full ERT Test Suite**:
   - Command:
     `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
   - Output:
     `Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:34:18+0000, 44.995830 sec)`
   - Exit Code: `0`.

8. **Strict Byte-Compilation**:
   - Compiled 20 production and test files under `(setq byte-compile-error-on-warn t)`.
   - Result: 0 warnings, 0 errors. Exit Code: `0`.

9. **Hygiene & Governance**:
   - `find . -name "*.elc"` -> 0 files.
   - `git status --porcelain skills.md .gitignore` -> empty.
   - `git diff skills.md .gitignore` -> empty.
   - `.agents/rules/architecture_principles.md` -> timestamp Oct 19 20:00, untouched.

10. **Formal TLC Model Checking**:
    - `ApprovalMC.tla`: 8,194 states generated, 1,536 distinct states, 0 errors.
    - `TransportMC.tla`: 1,810 states generated, 693 distinct states, 0 errors.

---

## 2. Logic Chain

1. From Observation 1 and Observation 3, mutating tools lacking explicit policy now fall back to `mutating-tools` check in `kargu-tool-execution--validate-gate`. When invoked in `ask` mode, the gate returns `:mode-forbidden` without executing, leaving the target file contents on disk completely unmodified (`"initial\n"`). This proves Defect 1 is genuinely resolved without facades or hardcoding.
2. From Observation 1 and Observation 4, `kargu-tool-gate-execute` places the `(approval ...)` check unconditionally at the top of the execution dispatch `cond`. Passing an approval token to any tool immediately verifies and claims the token (`claimed-p = t`). Attempting to replay the same token fails with `:approval-stale`, and the executor is never invoked a second time (`executed=1`). This proves Defect 2 is genuinely resolved.
3. From Observation 2 and Observation 5, `kargu-tool-registry--policy-p` allows `:needs-approval-p`, accepts valid boolean values (`t` and `nil`), and rejects invalid types with a contract error. This proves Defect 3 is genuinely resolved.
4. From Observation 6 and Observation 7, the entire test suite passes with 1052/1052 passing tests, including all 22 Package D contract tests.
5. From Observations 8, 9, and 10, byte compilation, checkdoc linting, TLC formal model checks, and repository governance checks all pass cleanly with zero warnings, zero errors, zero `.elc` artifacts, and zero modifications to protected files (`skills.md`, `.gitignore`, `.agents/`).

---

## 3. Caveats

No caveats. All 3 defects identified by Challenger 1 have been remediated, verified empirically via batch scripts, tested across the full ERT suite (1052 tests), and verified under formal TLC model checking.

---

## 4. Conclusion

**Verdict: CLEAN**

The Wave 2 Iteration 2 Remediation is authentic, robust, and completely free of integrity violations, dummy facades, or weakened test assertions. All requirements and acceptance criteria from `ORIGINAL_REQUEST.md` for Wave 2 are met.

---

## 5. Verification Method

To independently reproduce and verify this audit:

1. **Verify Full ERT Test Suite (1052 tests)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
   ```
   *Expected:* `Ran 1052 tests, 1052 results as expected, 0 unexpected`.

2. **Verify Mode Gating (Challenge 1)**:
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
   *Expected:* `RESULT: "ERROR: Tool edit_file is unavailable in ask mode."`, `DISK: "initial\n"`.

3. **Verify Approval Token Claim & Anti-Replay (Challenge 2)**:
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
   *Expected:* Exec 1 `res="OK"`; Exec 2 `res="ERROR: Approval token has already been claimed (replay rejected)"`, `executed=1`.

4. **Verify Strict Byte-Compilation and Hygiene**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f (list "kargu/tools/registry.el" "kargu/tools/execution.el" "tests/test-tool-execution-contract.el" "tests/test-tools.el")) (byte-compile-file f)))'
   find . -name "*.elc" -delete
   find . -name "*.elc"
   git status --porcelain skills.md .gitignore
   ```
   *Expected:* Zero warnings on byte compilation, both find and git status commands output empty.
