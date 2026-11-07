# Handoff Report: Wave 2 Iteration 2 Empirical Challenger

**Agent**: `challenger_wave2_it2_1`  
**Parent Agent**: `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date**: 2026-10-22T04:36:15Z  
**Type**: Hard Handoff (Task Complete)  
**Verdict**: **APPROVE**  

---

## 1. Observation

1. **Challenge 1 (Mode Gating Verification)**:
   - Tool `edit_file` with arguments modifying a temporary file was executed via `kargu-tool-gate-execute-sync` with context `:mode 'ask'` while global session mode was set to `agent`:
     - Gate validation directly returned:
       `GATE-CHECK-CODE: :mode-forbidden`
       `GATE-CHECK-MSG: "ERROR: Tool edit_file is unavailable in ask mode."`
       `GATE-CHECK-DATA: (:tool "edit_file" :mode ask)`
     - Sync execution returned verbatim: `"ERROR: Tool edit_file is unavailable in ask mode."`
     - Disk content of target file: `"ORIGINAL_CONTENT\n"` (file on disk remained untouched).
   - Tools `edit_file`, `bash`, and `git_commit` tested in context `:mode 'plan'`:
     - All 3 returned `:mode-forbidden`.
   - Tool `edit_file` tested in context `:mode 'agent'`:
     - Result verbatim: `"APPLIED: the change to ... has been applied and the file is saved. Verify it with lsp_diagnostics."`
     - Disk content verified: `"MUTATED_BY_AGENT\n"`.

2. **Challenge 2 (Single-Use Approval Anti-Replay Verification)**:
   - Tool `op` (general tool registered with `:policy '(:modes (agent))`) was executed twice with a single `kargu-tool-approval` token:
     - Initial token state: `claimed-p = nil`.
     - Execution 1 result verbatim: `"OP_SUCCESS"`.
     - Post-Execution 1 token state: `claimed-p = t`.
     - Post-Execution 1 executed counter: `1`.
     - Direct check `(kargu-tool-approval-claim token ...)` returned: `:approval-stale`.
     - Execution 2 (Replay) result verbatim: `"ERROR: Approval token has already been claimed (replay rejected)"`.
     - Post-Execution 2 token state: `claimed-p = t`.
     - Post-Execution 2 executed counter: `1` (executor was NOT re-entered).
     - Execution 3 (Repeated Replay) result verbatim: `"ERROR: Approval token has already been claimed (replay rejected)"` (executed counter remained `1`).
   - Token binding mismatch checks:
     - Wrong tool name: `"ERROR: Approval tool name mismatch"` (code `:approval-mismatch`).
     - Wrong root directory: `"ERROR: Approval directory root mismatch"` (code `:approval-mismatch`).
     - Wrong arguments hash: `"ERROR: Approval arguments hash mismatch"` (code `:approval-mismatch`).
     - Stale policy revision: `"ERROR: Approval policy revision mismatch"` (code `:approval-mismatch`).
     - Executed counter remained `0` across all mismatch attempts.

3. **Challenge 3 (Tool Policy Schema Verification)**:
   - Registration with `:policy '(:modes (agent) :needs-approval-p t)` succeeded, returning `"t1"`. Definition policy inspection verified `(:modes (agent) :needs-approval-p t)`.
   - Registration with `:policy '(:modes (agent) :needs-approval-p nil)` succeeded, returning `"t2"`. Definition policy inspection verified `(:modes (agent) :needs-approval-p nil)`.
   - Registration with all 3 policy keys `(:modes (agent ask) :available-p (function ignore) :needs-approval-p t)` succeeded, returning `"t3"`.
   - Non-boolean values for `:needs-approval-p` ("invalid", 1, 'yes, '(t), :true) were rejected with verbatim contract assertion errors:
     `Contract violation: (:modes (agent) :needs-approval-p ...) does not satisfy kargu-tool-registry--policy-p`.
   - Unrecognized key `:unknown-key` was rejected with:
     `Contract violation: (:modes (agent) :unknown-key t) does not satisfy kargu-tool-registry--policy-p`.

4. **Package D Contract Tests**:
   - `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (load-file "tests/test-tool-execution-contract.el"))' -f ert-run-tests-batch-and-exit`
   - Output: `Ran 22 tests, 22 results as expected, 0 unexpected (2026-10-22 04:31:59+0000, 0.036505 sec)`.
   - Exit code: `0`.

5. **Full Repository ERT Test Suite**:
   - `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
   - Output: `Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:34:44+0000, 44.621013 sec)`.
   - Exit code: `0`.

6. **Formal Verification (TLC)**:
   - `bash proof/run_tlc.sh --approval`: 8,194 states generated, 1,536 distinct states checked, 0 errors (exit code 0).
   - `bash proof/run_tlc.sh --transport`: 1,810 states generated, 693 distinct states checked, 0 errors (exit code 0).
   - `bash proof/run_tlc.sh --mode`: 20,179 states generated, 5,958 distinct states checked, 0 errors (exit code 0).

7. **Compilation, Linter & Repository Hygiene**:
   - Byte-compile with `byte-compile-error-on-warn t` on `kargu/tools/registry.el`, `kargu/tools/execution.el`, `tests/test-tool-execution-contract.el`, and `tests/test-tools.el`: 0 warnings, 0 errors (exit code 0).
   - Checkdoc: 0 warnings on all 4 files.
   - `skills.md` and `.gitignore`: clean and untouched (`git status --porcelain skills.md .gitignore` returned empty).
   - Leftover `.elc` files: 0.

---

## 2. Logic Chain

1. From Observation 1, `kargu-tool-execution--validate-gate` checks membership against mutating tools and forbids execution whenever the context mode is not `'agent`. When `edit_file` was invoked in `ask` mode, the gate returned `:mode-forbidden`, the tool was never executed, and disk content was unmodified. In `plan` mode, execution was likewise forbidden, while in `agent` mode, the tool executed and modified disk as intended. This directly confirms that Defect 1 is completely resolved.
2. From Observation 2, `kargu-tool-gate-execute` enforces that passing any `:approval` token unconditionally invokes `kargu-tool-approval-claim`. General tools now transition the token to `claimed-p = t` on execution 1, and any subsequent replay is rejected with `:approval-stale`. Furthermore, binding mismatches across tool name, root, arguments, and policy revisions are strictly enforced. This directly confirms that Defect 2 is completely resolved.
3. From Observation 3, `kargu-tool-registry--policy-p` permits boolean `:needs-approval-p` without contract errors, allows coexistence with `:modes` and `:available-p`, and strictly rejects non-boolean values and extra keys. This directly confirms that Defect 3 is completely resolved.
4. From Observations 4, 5, 6, and 7, all 22 contract tests pass, all 1052 tests in the entire ERT suite pass with 0 unexpected results, all TLC specifications pass model checking with 0 errors, and byte-compilation and checkdoc pass cleanly with 0 warnings.
5. Therefore, the remediation for Package D is complete, verified, robust against adversarial attacks, and ready for Wave 2 approval.

---

## 3. Caveats

- Testing was performed on Linux 6.18 x86_64; non-POSIX process fallback behavior (`windows-nt`) was reviewed statically in `kargu/tools/process.el` but not tested on a Windows kernel.

---

## 4. Conclusion

**Verdict: APPROVE**

The remediations in `kargu/tools/execution.el`, `kargu/tools/registry.el`, `tests/test-tool-execution-contract.el`, and `tests/test-tools.el` are fully verified by empirical test execution. All invariants hold, edge cases are guarded, and zero regressions exist. Package D is approved.

---

## 5. Verification Method

To independently reproduce the empirical findings:

1. **Verify Mode Gating (Challenge 1)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn
     (require (quote package)) (package-initialize)
     (require (quote kargu)) (require (quote kargu/tools/diff)) (require (quote kargu/tools/execution))
     (kargu-diff-register-tools)
     (setf (kargu-session-mode-value (kargu-session-context)) (quote agent))
     (let* ((reg kargu--tool-registry)
            (root (file-name-as-directory (expand-file-name default-directory)))
            (temp-file (expand-file-name "temp_verify_edit.txt" root)))
       (with-temp-file temp-file (insert "ORIGINAL\n"))
       (unwind-protect
           (let* ((ctx-ask (kargu-tool-execution-context-create :mode (quote ask) :root root))
                  (args (list (cons "file_path" temp-file) (cons "old_string" "ORIGINAL") (cons "new_string" "MUTATED")))
                  (res (kargu-tool-gate-execute-sync reg ctx-ask "edit_file" args))
                  (disk (with-temp-buffer (insert-file-contents temp-file) (buffer-string))))
             (message "RESULT: %S" res)
             (message "DISK: %S" disk)
             (unless (and (string-match-p "unavailable in ask mode" res) (equal disk "ORIGINAL\n"))
               (error "Verification failed")))
         (when (file-exists-p temp-file) (delete-file temp-file)))))'
   ```
   *Expected*: `RESULT: "ERROR: Tool edit_file is unavailable in ask mode."`, `DISK: "ORIGINAL\n"`.

2. **Verify Approval Single-Use Anti-Replay (Challenge 2)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn
     (require (quote package)) (package-initialize)
     (require (quote kargu)) (require (quote kargu/tools/registry)) (require (quote kargu/tools/execution))
     (let* ((reg (kargu-tool-registry-create))
            (root (file-name-as-directory (expand-file-name default-directory)))
            (executed 0))
       (kargu-tool-registry-register
        reg :name "op" :description "Op"
        :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
        :executor (lambda (args) (cl-incf executed) "OK")
        :policy (list :modes (quote (agent))))
       (let* ((ctx (kargu-tool-execution-context-create :root root :mode (quote agent) :policy-revision (kargu-tool-registry-revision reg)))
              (args (quote (("k" . "v"))))
              (token (kargu-tool-approval-create :tool-name "op" :args args :root root :policy-revision (kargu-tool-registry-revision reg))))
         (let ((r1 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
           (message "Claimed after exec 1: %S (res=%S)" (kargu-tool-approval-claimed-p token) r1))
         (let ((r2 (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)))
           (message "Claimed after exec 2: %S (executed=%d, res=%S)" (kargu-tool-approval-claimed-p token) executed r2)))))'
   ```
   *Expected*: `Claimed after exec 1: t (res="OK")`; `Claimed after exec 2: t (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)")`.

3. **Verify Tool Policy Schema (Challenge 3)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn
     (require (quote package)) (package-initialize) (require (quote kargu)) (require (quote kargu/tools/registry))
     (let ((reg (kargu-tool-registry-create)))
       (kargu-tool-registry-register reg :name "t1" :description "T1" :executor (function ignore)
        :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
        :policy (quote (:modes (agent) :needs-approval-p t)))
       (condition-case err
           (kargu-tool-registry-register reg :name "t2" :description "T2" :executor (function ignore)
            :parameters (quote (("type" . "object") ("properties" . :json-empty-object)))
            :policy (quote (:modes (agent) :needs-approval-p "invalid")))
         (error (message "Rejected bad policy: %s" (error-message-string err))))))'
   ```
   *Expected*: Registration of `t1` succeeds; `t2` rejected with `Contract violation: (:modes (agent) :needs-approval-p "invalid") does not satisfy kargu-tool-registry--policy-p`.

4. **Verify Contract Tests & ERT Suite**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (load-file "tests/test-tool-execution-contract.el"))' -f ert-run-tests-batch-and-exit
   ```
   *Expected*: `Ran 22 tests, 22 results as expected, 0 unexpected`.
