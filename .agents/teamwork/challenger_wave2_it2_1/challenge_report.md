# Wave 2 Iteration 2 Empirical Challenge Report

**Agent**: `challenger_wave2_it2_1`  
**Role**: Empirical Challenger (Adversarial Critic & Specialist)  
**Date**: 2026-10-22T04:35:45Z  
**Verdict**: **APPROVE**  

---

## 1. Challenge Summary

**Overall risk assessment**: **LOW**  
All 3 critical vulnerabilities identified in Iteration 1 (`challenger_wave2_1`) have been comprehensively remediated, tested, and empirically stress-tested:
1. **Defect 1 (Mode Gating Bypass)**: Remediated and verified. Mutating tools (`edit_file`, `bash`, `git_commit`, etc.) invoked in `ask` or `plan` execution contexts are strictly rejected at the gate with `:mode-forbidden`. Files on disk remain untouched. Session state cannot bypass context mode gating.
2. **Defect 2 (Approval Single-Use Replay Bypass)**: Remediated and verified. Every `:approval` token passed to `kargu-tool-gate-execute` is unconditionally verified and claimed via `kargu-tool-approval-claim` regardless of tool policy. First execution succeeds and sets `claimed-p = t`; replay executions are immediately rejected with `:approval-stale`.
3. **Defect 3 (Policy Schema Rejection of `:needs-approval-p`)**: Remediated and verified. `kargu-tool-registry--policy-p` permits boolean `:needs-approval-p`, safely coexists with `:modes` and `:available-p`, and strictly rejects non-boolean types (strings, integers, symbols, lists, keywords) and unrecognized policy keys with contract assertion errors.

---

## 2. Empirical Challenge Executions & Stress Tests

### Challenge 1: Mode Gating Bypass Verification

#### Hypothesis
When a mutating tool (such as `edit_file`) lacking an explicit `:policy` is invoked through `kargu-tool-gate-execute-sync` with an execution context in `:mode 'ask'`, the execution gate must return `:mode-forbidden`, abort before executor dispatch, and leave the target file on disk completely unchanged—even if global session state is set to `agent`.

#### Test Command
```bash
emacs -Q --batch -L . --eval '(progn
  (require (quote package)) (package-initialize)
  (require (quote kargu)) (require (quote kargu/tools/diff)) (require (quote kargu/tools/execution))
  (kargu-diff-register-tools)
  (setf (kargu-session-mode-value (kargu-session-context)) (quote agent))
  (let* ((reg kargu--tool-registry)
         (root (file-name-as-directory (expand-file-name default-directory)))
         (temp-file (expand-file-name "temp_challenge1_edit.txt" root)))
    (with-temp-file temp-file (insert "ORIGINAL_CONTENT\n"))
    (unwind-protect
        (let* ((ctx-ask (kargu-tool-execution-context-create :mode (quote ask) :root root))
               (args (list (cons "file_path" temp-file)
                           (cons "old_string" "ORIGINAL_CONTENT")
                           (cons "new_string" "MUTATED_CONTENT")))
               (gate-check (kargu-tool-execution--validate-gate reg ctx-ask "edit_file" args))
               (sync-res (kargu-tool-gate-execute-sync reg ctx-ask "edit_file" args))
               (disk-content (with-temp-buffer (insert-file-contents temp-file) (buffer-string))))
          (message "GATE-CHECK-CODE: %S" (kargu-result-err-code gate-check))
          (message "GATE-CHECK-MSG: %S" (kargu-result-err-message gate-check))
          (message "GATE-CHECK-DATA: %S" (kargu-result-err-data gate-check))
          (message "SYNC-RES: %S" sync-res)
          (message "DISK-CONTENT: %S" disk-content)
          (if (and (eq (kargu-result-err-code gate-check) :mode-forbidden)
                   (equal disk-content "ORIGINAL_CONTENT\n")
                   (string-match-p "unavailable in ask mode" sync-res))
              (message "CHALLENGE 1 (ASK MODE): PASSED")
            (error "CHALLENGE 1 (ASK MODE): FAILED")))
      (when (file-exists-p temp-file) (delete-file temp-file)))))'
```

#### Observed Output
```
GATE-CHECK-CODE: :mode-forbidden
GATE-CHECK-MSG: "ERROR: Tool edit_file is unavailable in ask mode."
GATE-CHECK-DATA: (:tool "edit_file" :mode ask)
SYNC-RES: "ERROR: Tool edit_file is unavailable in ask mode."
DISK-CONTENT: "ORIGINAL_CONTENT\n"
CHALLENGE 1 (ASK MODE): PASSED
```

#### Extended Attack Vectors Tested
- **Plan Mode Gating**: Mutating tools `edit_file`, `bash`, and `git_commit` tested in context `:mode 'plan'`. All 3 returned `:mode-forbidden`.
- **Agent Mode Execution**: In context `:mode 'agent'`, `edit_file` successfully executed, resulting in `"APPLIED: the change to ... has been applied and the file is saved."` and disk content updated to `"MUTATED_BY_AGENT\n"`.

---

### Challenge 2: Approval Token Single-Use Anti-Replay

#### Hypothesis
When an approval token is generated and passed to a general tool (e.g. `op` without approval requirements in its policy), the execution gate must claim the token during execution 1 (`claimed-p` transitions to `t`). A second execution attempt reusing the same token must be rejected with `:approval-stale`, and the tool executor must not be called again.

#### Test Command
```bash
emacs -Q --batch -L . --eval '(progn
  (require (quote package)) (package-initialize)
  (require (quote kargu)) (require (quote kargu/tools/registry)) (require (quote kargu/tools/execution))
  (let* ((reg (kargu-tool-registry-create))
         (root (file-name-as-directory (expand-file-name default-directory)))
         (executed 0))
    (kargu-tool-registry-register
     reg :name "op" :description "General Operation"
     :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
     :executor (lambda (args) (cl-incf executed) "OP_SUCCESS")
     :policy (list :modes (quote (agent))))

    (let* ((ctx (kargu-tool-execution-context-create
                 :root root :mode (quote agent)
                 :policy-revision (kargu-tool-registry-revision reg)))
           (args (quote (("foo" . "bar"))))
           (token (kargu-tool-approval-create
                   :tool-name "op" :args args :root root
                   :policy-revision (kargu-tool-registry-revision reg))))

      (message "Initial claimed-p: %S" (kargu-tool-approval-claimed-p token))
      (unless (eq (kargu-tool-approval-claimed-p token) nil)
        (error "Token should not be claimed initially"))

      ;; Execution 1
      (let ((res1 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
        (message "Execution 1 res: %S" res1)
        (message "Claimed after exec 1: %S" (kargu-tool-approval-claimed-p token))
        (message "Executed count after exec 1: %d" executed)
        (unless (and (equal res1 "OP_SUCCESS")
                     (eq (kargu-tool-approval-claimed-p token) t)
                     (= executed 1))
          (error "Execution 1 failed verification")))

      ;; Direct check of kargu-tool-approval-claim on claimed token
      (let ((claim-check (kargu-tool-approval-claim token :tool-name "op" :args args
                                                  :root root
                                                  :policy-revision (kargu-tool-registry-revision reg))))
        (message "Direct claim-check code: %S" (kargu-result-err-code claim-check))
        (unless (eq (kargu-result-err-code claim-check) :approval-stale)
          (error "Direct claim-check did not return :approval-stale")))

      ;; Execution 2 (Replay)
      (let ((res2 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
        (message "Execution 2 res: %S" res2)
        (message "Claimed after exec 2: %S" (kargu-tool-approval-claimed-p token))
        (message "Executed count after exec 2: %d" executed)
        (unless (and (string-match-p "already been claimed" res2)
                     (eq (kargu-tool-approval-claimed-p token) t)
                     (= executed 1))
          (error "Execution 2 failed verification")))

      ;; Execution 3 (Repeated Replay)
      (let ((res3 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
        (message "Execution 3 res: %S" res3)
        (unless (and (string-match-p "already been claimed" res3)
                     (= executed 1))
          (error "Execution 3 failed verification")))

      (message "CHALLENGE 2 (APPROVAL SINGLE-USE): PASSED"))))'
```

#### Observed Output
```
Initial claimed-p: nil
Execution 1 res: "OP_SUCCESS"
Claimed after exec 1: t
Executed count after exec 1: 1
Direct claim-check code: :approval-stale
Execution 2 res: "ERROR: Approval token has already been claimed (replay rejected)"
Claimed after exec 2: t
Executed count after exec 2: 1
Execution 3 res: "ERROR: Approval token has already been claimed (replay rejected)"
CHALLENGE 2 (APPROVAL SINGLE-USE): PASSED
```

#### Extended Attack Vectors Tested
- **Token Binding Mismatches**:
  - Wrong tool name: rejected with `"ERROR: Approval tool name mismatch"`.
  - Wrong directory root: rejected with `"ERROR: Approval directory root mismatch"`.
  - Wrong arguments hash: rejected with `"ERROR: Approval arguments hash mismatch"`.
  - Stale policy revision: rejected with `"ERROR: Approval policy revision mismatch"`.
  - In all mismatch cases, `executed` remained 0.
- **Dynamic vs Pre-approved Token Integration**:
  - Tool registered with `:needs-approval-p t`.
  - Execution without token invokes dynamic approval prompt; approval `t` proceeds to run; denial terminates with `"ERROR: Command was not approved by the user"`.
  - Execution with pre-generated token skips dynamic prompt, claims the token, and rejects replays.

---

### Challenge 3: Tool Policy Schema Validation

#### Hypothesis
`kargu-tool-registry--policy-p` must permit `:needs-approval-p` with boolean values (`t` and `nil`), must allow all valid combinations with `:modes` and `:available-p`, and must strictly reject non-boolean `:needs-approval-p` values (strings, integers, symbols, lists, keywords) and unrecognized policy keys with contract assertion errors.

#### Test Command
```bash
emacs -Q --batch -L . --eval '(progn
  (require (quote package)) (package-initialize)
  (require (quote kargu)) (require (quote kargu/tools/registry))
  (let ((reg (kargu-tool-registry-create)))
    ;; 1. Valid registration with :needs-approval-p t
    (let ((n1 (kargu-tool-registry-register
               reg :name "t1" :description "Tool 1" :executor (function ignore)
               :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
               :policy (quote (:modes (agent) :needs-approval-p t)))))
      (unless (equal n1 "t1") (error "t1 registration failed"))
      (let ((pol (kargu-tool-definition-policy (kargu-tool-registry-find reg "t1"))))
        (unless (and (equal (plist-get pol :modes) (quote (agent)))
                     (eq (plist-get pol :needs-approval-p) t))
          (error "t1 policy content mismatch: %S" pol))))

    ;; 2. Valid registration with :needs-approval-p nil
    (let ((n2 (kargu-tool-registry-register
               reg :name "t2" :description "Tool 2" :executor (function ignore)
               :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
               :policy (quote (:modes (agent) :needs-approval-p nil)))))
      (unless (equal n2 "t2") (error "t2 registration failed"))
      (let ((pol (kargu-tool-definition-policy (kargu-tool-registry-find reg "t2"))))
        (unless (and (equal (plist-get pol :modes) (quote (agent)))
                     (eq (plist-get pol :needs-approval-p) nil))
          (error "t2 policy content mismatch: %S" pol))))

    ;; 3. Valid registration with all keys: :modes, :available-p, :needs-approval-p
    (let ((n3 (kargu-tool-registry-register
               reg :name "t3" :description "Tool 3" :executor (function ignore)
               :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
               :policy (list :modes (quote (agent ask)) :available-p (function ignore) :needs-approval-p t))))
      (unless (equal n3 "t3") (error "t3 registration failed")))

    ;; 4. Verify rejections of non-boolean :needs-approval-p
    (dolist (bad-val (list "invalid" 1 (quote yes) (quote (t)) :true))
      (condition-case err
          (progn
            (kargu-tool-registry-register
             reg :name "bad_tool" :description "Bad" :executor (function ignore)
             :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
             :policy (list :modes (quote (agent)) :needs-approval-p bad-val))
            (error "Failed to reject non-boolean %S" bad-val))
        (error
         (unless (string-match-p "kargu-tool-registry--policy-p" (error-message-string err))
           (error "Unexpected error for %S: %S" bad-val err))
         (message "Correctly rejected non-boolean %S: %s" bad-val (error-message-string err)))))

    ;; 5. Verify rejection of unknown key
    (condition-case err
        (progn
          (kargu-tool-registry-register
           reg :name "bad_key" :description "Bad" :executor (function ignore)
           :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
           :policy (quote (:modes (agent) :unknown-key t)))
          (error "Failed to reject unknown key"))
      (error
       (unless (string-match-p "kargu-tool-registry--policy-p" (error-message-string err))
         (error "Unexpected error for unknown key: %S" err))
       (message "Correctly rejected unknown key: %s" (error-message-string err))))

    (message "CHALLENGE 3 (POLICY SCHEMA): PASSED")))'
```

#### Observed Output
```
Correctly rejected non-boolean "invalid": Contract violation: (:modes (agent) :needs-approval-p "invalid") does not satisfy kargu-tool-registry--policy-p
Correctly rejected non-boolean 1: Contract violation: (:modes (agent) :needs-approval-p 1) does not satisfy kargu-tool-registry--policy-p
Correctly rejected non-boolean yes: Contract violation: (:modes (agent) :needs-approval-p yes) does not satisfy kargu-tool-registry--policy-p
Correctly rejected non-boolean (t): Contract violation: (:modes (agent) :needs-approval-p (t)) does not satisfy kargu-tool-registry--policy-p
Correctly rejected non-boolean :true: Contract violation: (:modes (agent) :needs-approval-p :true) does not satisfy kargu-tool-registry--policy-p
Correctly rejected unknown key: Contract violation: (:modes (agent) :unknown-key t) does not satisfy kargu-tool-registry--policy-p
CHALLENGE 3 (POLICY SCHEMA): PASSED
```

---

## 3. Regression & Contract Test Results

1. **Package D Contract Test Suite (`tests/test-tool-execution-contract.el`)**:
   - `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (load-file "tests/test-tool-execution-contract.el"))' -f ert-run-tests-batch-and-exit`
   - **Result**: `Ran 22 tests, 22 results as expected, 0 unexpected (0.036505 sec)`. Exit code: `0`.
2. **Full Repository ERT Test Suite**:
   - `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
   - **Result**: `Ran 1052 tests, 1052 results as expected, 0 unexpected (44.621013 sec)`. Exit code: `0`.
3. **Formal Specification Checking (TLC)**:
   - `bash proof/run_tlc.sh --approval`: 8,194 states generated, 1,536 distinct states checked, 0 errors.
   - `bash proof/run_tlc.sh --transport`: 1,810 states generated, 693 distinct states checked, 0 errors.
   - `bash proof/run_tlc.sh --mode`: 20,179 states generated, 5,958 distinct states checked, 0 errors.
4. **Byte Compilation & Linters**:
   - `(setq byte-compile-error-on-warn t)` across all 4 touched files: 0 warnings, 0 errors.
   - `checkdoc-file` across all touched files: 0 warnings.
   - `git status --porcelain skills.md .gitignore`: clean and untouched.
   - `find . -name "*.elc"`: 0 leftover files.

---

## 4. Unchallenged Areas

- Non-POSIX process signaling fallback on `windows-nt` was not tested natively, as execution environment is Linux 6.18 x86_64.

---

## 5. Conclusion

**Verdict: APPROVE**

The remediation implemented in `kargu/tools/execution.el`, `kargu/tools/registry.el`, `tests/test-tool-execution-contract.el`, and `tests/test-tools.el` completely and cleanly eliminates all 3 reported vulnerabilities without regressions.
