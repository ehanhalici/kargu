# Handoff Report: Wave 2 Iteration 2 Remediation Analysis (Package D)

**Agent:** `explorer_wave2_it2_1`  
**Parent Conversation ID:** `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date:** 2026-10-22T04:25:00Z  
**Type:** Hard Handoff (Analysis & Verification Complete)  
**Status:** **REMEDIATION_READY**

---

## 1. Observation

1. **Defect 1 Reproduction (Mode Gating Bypass)**:
   - Tool execution gate in `kargu/tools/execution.el` lines 371–379 previously inspected `(plist-get policy :modes)`.
   - Running `edit_file` in an explicit context of `:mode 'ask'` with session state `agent` bypassed gate rejection and modified disk content:
     - Gate result: `"APPLIED: the change to ... has been applied and the file is saved."`
     - Disk content: `"MUTATED IN ASK MODE!\n"`.
   - After remediation (`kargu-tool-execution--validate-gate` checking `kargu-loop-mutating-tools` when `cur-mode` is not `'agent`):
     - Gate result: `"ERROR: Tool edit_file is unavailable in ask mode."`
     - Disk content: untouched (`"initial content\n"`).

2. **Defect 2 Reproduction (Approval Token Replay on General Tools)**:
   - In `kargu/tools/execution.el` lines 445–470, `(when (and needs-appr approval) ...)` only claimed approval tokens when `needs-appr` was truthy. For general tools, `needs-appr` evaluated to `nil`.
   - Executing a general tool twice with the same approval token resulted in:
     - Initial token `claimed-p: nil`
     - Post Exec 1: `claimed-p: nil (executed=1)`
     - Post Exec 2 (Replay): `claimed-p: nil (executed=2)`
   - After remediation (restructuring to `cond` where `approval` unconditionally claims via `kargu-tool-approval-claim`):
     - Initial token `claimed-p: nil`
     - Post Exec 1: `claimed-p: t (executed=1, res="OK")`
     - Post Exec 2 (Replay): `claimed-p: t (executed=1, res="ERROR: Approval token has already been claimed (replay rejected)")`.

3. **Defect 3 Reproduction (Registry Policy Schema Rejects `:needs-approval-p`)**:
   - `kargu-tool-registry--policy-p` allowed only `(:modes :available-p)` via `(memq key '(:modes :available-p))`.
   - Calling `kargu-tool-registry-register` with `:policy '(:modes (agent) :needs-approval-p t)` signaled:
     `Contract violation: (:modes (agent) :needs-approval-p t) does not satisfy kargu-tool-registry--policy-p`.
   - After remediation (`always (memq key '(:modes :available-p :needs-approval-p))` and `(booleanp (plist-get policy :needs-approval-p))`):
     Tool definition registers cleanly and accurately retains `:needs-approval-p t`.

4. **Test Suite Verification**:
   - Full ERT suite command:
     `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
   - Verbatim output:
     `Ran 1052 tests, 1052 results as expected, 0 unexpected (2026-10-22 04:23:13+0000, 43.959009 sec)`
   - Exit code: 0.

5. **Byte Compilation Verification**:
   - Command:
     `(setq byte-compile-error-on-warn t)` on `kargu/tools/registry.el`, `kargu/tools/execution.el`, `tests/test-tool-execution-contract.el`, and `tests/test-tools.el`.
   - Result: 0 errors, 0 warnings.
   - Cleaned `.elc` files: `find . -name "*.elc"` returns 0 matches.

6. **Checkdoc Verification**:
   - Command:
     `checkdoc-file` on all 4 affected files.
   - Result: 0 warnings.

7. **TLC Formal Model Verification**:
   - Commands:
     `bash proof/run_tlc.sh --approval` -> 8,194 states generated, 1,536 distinct states, 0 errors.
     `bash proof/run_tlc.sh --mode` -> 20,179 states generated, 5,958 distinct states, 0 errors.
     `bash proof/run_tlc.sh --budget` -> 1,591 states generated, 432 distinct states, 0 errors.
     `bash proof/run_tlc.sh --process` -> 535 states generated, 179 distinct states, 0 errors.
     `bash proof/run_tlc.sh --transport` -> 1,810 states generated, 693 distinct states, 0 errors.

8. **Repository Governance & Hygiene**:
   - `git status --porcelain skills.md .gitignore` -> completely empty.
   - No temporary or extraneous files left in repo.

---

## 2. Logic Chain

1. From Observation 1, checking `kargu-loop-mutating-tools` in `kargu-tool-execution--validate-gate` when `cur-mode` is not `'agent` guarantees that tools without explicit `:policy` (such as `edit_file`, `bash`, `git_commit`) cannot be executed in read-only interaction modes (`ask` / `plan`). Disk mutation in `ask` mode is thereby completely prevented at the gate level, satisfying ARCH-02 and Contract 5 Section 5.5.
2. From Observation 2, restructuring `kargu-tool-gate-execute` so that any invocation providing an `:approval` token unconditionally invokes `kargu-tool-approval-claim` ensures that `(kargu-tool-approval-claimed-p token)` transitions to `t` on first use. Any subsequent attempt to reuse the token returns `:approval-stale`. Replay attacks across all tools are eliminated, satisfying ARCH-03 and Contract 5 Section 5.6.
3. From Observation 3, permitting `:needs-approval-p` (boolean) in `kargu-tool-registry--policy-p` aligns the registry contract with gate approval policies, enabling explicit declaration of approval requirements on tools.
4. From Observation 4, adding `(_ (kargu-test-mode 'agent))` to `kargu-execute-tool-async-bash-test` properly isolates this test's mode to `'agent`, aligning it with all other mutating tool tests in `tests/test-tools.el` and allowing all 1052 ERT tests across the entire suite to pass with zero failures.
5. From Observations 5, 6, 7, and 8, byte-compilation under `byte-compile-error-on-warn t`, checkdoc linters, exhaustive TLC model checking, and repository governance checks all pass cleanly without regressions.

---

## 3. Caveats

- In `tests/test-tools.el`, `kargu-execute-tool-async-bash-test` previously executed `bash` without establishing session mode `agent`, which passed only because `bash` previously lacked mode gating. Explicitly scoping this test with `(_ (kargu-test-mode 'agent))` is required for test suite passing under strict mode gating.
- Feature implementations in `kargu/tools/diff.el`, `kargu/tools/bash.el`, and `kargu/tools/git.el` were not modified; mode enforcement is centralized entirely in the unified gate (`kargu/tools/execution.el`).

---

## 4. Conclusion

**Verdict: REMEDIATION_READY**

All 3 defects identified by Challenger 1 have been completely diagnosed, remediated, and verified.
Detailed before/after code blocks and analysis are documented in:
`/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_it2_1/remediation_report.md`.

Tracked diff patch is available at:
`/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_it2_1/tracked_remediation.patch`.

---

## 5. Verification Method

To independently verify this remediation:

1. **Verify Full ERT Test Suite (1052 tests)**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
   ```
   *Expected:* `Ran 1052 tests, 1052 results as expected, 0 unexpected`. Exit code 0.

2. **Verify Mode Gating on Mutating Tools in Ask Mode**:
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

3. **Verify Approval Single-Use Claim and Anti-Replay on General Tools**:
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
   *Expected:* Exec 1 returns `"OK"` and `claimed-p = t`. Exec 2 returns `"ERROR: Approval token has already been claimed (replay rejected)"` and `executed = 1`.

4. **Verify Byte-Compilation Cleanliness**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f (list "kargu/tools/registry.el" "kargu/tools/execution.el" "tests/test-tool-execution-contract.el" "tests/test-tools.el")) (byte-compile-file f)))'
   find . -name "*.elc" -delete
   ```
   *Expected:* Exit code 0, 0 warnings.

5. **Verify Checkdoc Cleanliness**:
   ```bash
   emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (require (quote checkdoc)) (dolist (f (list "kargu/tools/registry.el" "kargu/tools/execution.el" "tests/test-tool-execution-contract.el" "tests/test-tools.el")) (checkdoc-file f)))'
   ```
   *Expected:* Exit code 0, 0 warnings.

6. **Verify Formal Models with TLC**:
   ```bash
   bash proof/run_tlc.sh --approval
   bash proof/run_tlc.sh --mode
   bash proof/run_tlc.sh --budget
   bash proof/run_tlc.sh --process
   bash proof/run_tlc.sh --transport
   ```
   *Expected:* Model checking completed with 0 errors across all specs.
