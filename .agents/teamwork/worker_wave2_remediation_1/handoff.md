# Handoff Report: Wave 2 Package D Remediation

**Agent:** `worker_wave2_remediation_1`  
**Parent Agent:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T04:30:15Z  
**Type:** Hard Handoff (Task Complete)  
**Verdict:** **REMEDIATION_COMPLETE**

---

## 1. Observation

1. **Remediation Implementation in `kargu/tools/execution.el`**:
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
                      :mode-forbidden (list :tool name :mode cur-mode))))
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

2. **Remediation Implementation in `kargu/tools/registry.el`**:
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

3. **Remediation Implementation in `tests/test-tool-execution-contract.el` & `tests/test-tools.el`**:
   - Tests 20, 21, and 22 present at lines 413–501 in `tests/test-tool-execution-contract.el`.
   - `kargu-execute-tool-async-bash-test` in `tests/test-tools.el` scoped with `(_ (kargu-test-mode 'agent))` at lines 488–492.

4. **Challenger Empirical Script 1 Execution**:
   - Command: Invocation of `edit_file` in an `ask` context with session set to `agent`.
   - Result:
     ```
     RESULT: "ERROR: Tool edit_file is unavailable in ask mode."
     DISK: "initial\n"
     ```

5. **Challenger Empirical Script 2 Execution**:
   - Command: Dual execution of general tool `op` using the same approval token.
   - Result:
     ```
     Claimed after exec 1: t (res="OK")
     Claimed after exec 2: t (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)")
     ```

6. **Challenger Empirical Script 3 Execution**:
   - Command: Registering tools with `:needs-approval-p t`, `:needs-approval-p nil`, and `:needs-approval-p "invalid"`.
   - Result:
     ```
     Registered with t: "test_appr_t", with nil: "test_appr_nil"
     Policy retrieved: (:modes (agent) :needs-approval-p t)
     Expected rejection of non-boolean: (error "Contract violation: (:modes (agent) :needs-approval-p \"invalid\") does not satisfy kargu-tool-registry--policy-p")
     ```

7. **Full ERT Suite**:
   - Command:
     `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
   - Output:
     `Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:28:45+0000, 44.185120 sec)`
   - Exit Code: `0`.

8. **Byte-Compilation and Checkdoc**:
   - Byte-compile with `byte-compile-error-on-warn t` on `kargu/tools/registry.el`, `kargu/tools/execution.el`, `tests/test-tool-execution-contract.el`, `tests/test-tools.el` -> 0 warnings, 0 errors (exit code 0).
   - Checkdoc on all 4 files -> 0 warnings (exit code 0).
   - `find . -name "*.elc"` -> 0 files.

9. **TLC Model Checking**:
   - `bash proof/run_tlc.sh --approval` -> 8,194 states generated, 1,536 distinct states, 0 errors.
   - `bash proof/run_tlc.sh --transport` -> 1,810 states generated, 693 distinct states, 0 errors.

10. **Repository Hygiene**:
    - `git status --porcelain skills.md .gitignore` -> completely empty.

---

## 2. Logic Chain

1. From Observation 1 and Observation 4, gating mutating tools in `kargu-tool-execution--validate-gate` guarantees that tools like `edit_file`, `bash`, and `git_commit` cannot execute or modify files when context mode is `ask` or `plan`. The verification script proved that the file contents remained `"initial\n"` while returning `:mode-forbidden`. This completely resolves Defect 1.
2. From Observation 1 and Observation 5, restructuring `kargu-tool-gate-execute` so that any invocation supplying an `:approval` token unconditionally invokes `kargu-tool-approval-claim` ensures that general tools transition the token to `claimed-p = t` on execution 1, and subsequent replays on execution 2 are rejected with `:approval-stale`. This completely resolves Defect 2.
3. From Observation 2 and Observation 6, updating `kargu-tool-registry--policy-p` allows tools to declare `:needs-approval-p` boolean policies without triggering contract violations, while properly rejecting invalid non-boolean types. This completely resolves Defect 3.
4. From Observation 3 and Observation 7, scoping `kargu-execute-tool-async-bash-test` with `(_ (kargu-test-mode 'agent))` aligns with the mode gating requirement for `bash`, enabling the entire ERT suite of 1052 tests (including newly added Tests 20, 21, and 22) to pass cleanly with zero failures.
5. From Observations 8, 9, and 10, byte compilation, checkdoc linters, TLC model checkers, and git hygiene checks pass cleanly without regressions.

---

## 3. Caveats

- No caveats. All 3 defects identified by Challenger 1 have been tested and verified across both unit tests and empirical challenger scripts.

---

## 4. Conclusion

**Verdict: REMEDIATION_COMPLETE**

Package D remediation is fully in place, verified, and ready for Wave 2 closure. All challenger issues are closed with empirical proof, all tests pass, and zero regressions or hygiene violations exist.

---

## 5. Verification Method

To independently verify:

1. **Verify Full ERT Test Suite (1052 tests)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
   ```
   *Expected:* `Ran 1052 tests, 1052 results as expected, 0 unexpected`.

2. **Verify Challenger Scripts**:
   - Mutating tool in ask mode:
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

   - Approval token claim and anti-replay:
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
     *Expected:* Claimed after exec 1: `t` (res="OK"); Claimed after exec 2: `t` (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)").

3. **Verify TLC Models**:
   ```bash
   bash proof/run_tlc.sh --approval
   bash proof/run_tlc.sh --transport
   ```
   *Expected:* Exit code 0, 0 errors.

4. **Verify Hygiene**:
   ```bash
   git status --porcelain skills.md .gitignore
   find . -name "*.elc"
   ```
   *Expected:* Both empty.
