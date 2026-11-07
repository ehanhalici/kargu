# Handoff Report: Wave 2 Empirical Challenger 1

**Agent**: `challenger_wave2_1`  
**Parent Agent**: `246e42bd-e1b7-4f73-8026-d90704dd17ec`  
**Date**: 2026-10-22T04:07:30Z  
**Type**: Hard Handoff  
**Verdict**: **REQUEST_CHANGES**

---

## 1. Observation

1. **Mode Gating Bypass in Tool Execution Gate**:
   - `kargu/tools/execution.el`, line 32 declares `(defvar kargu-loop-mutating-tools)`.
   - Lines 371–379:
     ```elisp
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
   - In production tools, `kargu-diff-register-tools` (`kargu/tools/diff.el:892`), `kargu-bash-register-tools` (`kargu/tools/bash.el:132`), and `kargu-git-register-tools` (`kargu/tools/git.el:661`) register definitions where `policy` is `nil`.
   - When calling `kargu-tool-execution--validate-gate` on `edit_file`, `bash`, and `git_commit` with `context` in `:mode 'ask'` or `:mode 'plan'`, the gate returned:
     `#s(kargu-result-ok ("edit_file" ...))`
     `#s(kargu-result-ok ("bash" ...))`
     `#s(kargu-result-ok ("git_commit" ...))`
   - Furthermore, when session state mode was `agent` (`(setf (kargu-session-mode-value (kargu-session-context)) 'agent)`), executing `edit_file` through the gate with a context in `:mode 'ask'` or `:mode 'plan'` executed the file modification and saved it to disk:
     Verbatim tool output: `"APPLIED: the change to /home/emrehan/.emacs.local/kargu/temp_test_edit.txt has been applied and the file is saved. Verify it with lsp_diagnostics."`
     Verbatim file content: `"MUTATED IN ASK MODE!\n"`.

2. **Single-Use Approval Token Replay Vulnerability for General Tools**:
   - `kargu/tools/execution.el`, lines 445–470:
     ```elisp
     (let ((needs-appr
            (or (and policy (plist-get policy :needs-approval-p))
                (and (equal canonical "bash")
                     (bound-and-true-p kargu-permission-confirm-bash)))))
       (if (and needs-appr (not approval))
           ...
         (when (and needs-appr approval)
           ;; Token provided -> Claim it
           (let ((claim (kargu-tool-approval-claim ...))))))
     ```
   - For all tools other than `"bash"`, `needs-appr` evaluates to `nil`.
   - When a caller generates a valid `kargu-tool-approval` token and executes the tool passing `:approval token`:
     `kargu-tool-approval-claim` is never called.
     Verbatim output across consecutive executions:
     ```
     Token before exec 1: claimed-p = nil
     Post Exec 1: claimed-p = nil (executed=1)
     Post Exec 2 (Replay!): claimed-p = nil (executed=2)
     ```
     The single-use approval invariant was completely bypassed.

3. **Inconsistent Policy Schema in `kargu/tools/registry.el`**:
   - `kargu/tools/registry.el`, lines 57–66:
     ```elisp
     (defun kargu-tool-registry--policy-p (policy)
       (and (proper-list-p policy)
            (cl-evenp (length policy))
            (cl-loop for (key _value) on policy by #'cddr
                     always (memq key '(:modes :available-p)))
            (proper-list-p (plist-get policy :modes))
            (seq-every-p #'kargu-contract-mode-p (plist-get policy :modes))
            (kargu-contract-callback-p (plist-get policy :available-p))))
     ```
   - Attempting to register a tool with `:policy '(:modes (agent) :needs-approval-p t)` signals:
     `Contract violation: (:modes (agent) :needs-approval-p t) does not satisfy kargu-tool-registry--policy-p`.

4. **Policy Revision Staleness Rejection**:
   - Mutating a tool definition/policy incremented registry revision from 1 to 2.
   - Using the approval token captured at revision 1 in `kargu-tool-gate-execute-sync` with a revision-2 context was rejected immediately:
     Verbatim output: `"ERROR: Approval policy revision mismatch"`.
     Typed result: `#s(kargu-result-err "Approval policy revision mismatch" :approval-mismatch nil)`.

5. **Registry Draining Invariant**:
   - Marking a tool as draining via `kargu-tool-registry-mark-draining` resulted in immediate gate rejection:
     Typed result: `#s(kargu-result-err "ERROR: tool draining_tool is currently draining/unloading" :tool-draining (:name "draining_tool"))`.

6. **Process Group Cancellation Without Orphan Leaks (RISK-01)**:
   - Started a nested background process: `sh -c "(sleep 10 &) & echo $!; wait"`.
   - Main proc PID was 1247518; background sleeper was PID 1247520 (`pgrp = 1247518`, `ppid = 1`).
   - Invoked `(kargu-process-cancel proc)`.
   - Checked `/proc` filesystem: sleeper PID 1247520 was terminated instantly; `(process-attributes 1247520)` returned `nil`. 0 orphan processes remained.

7. **Dead Process Wait Loop CPU Benchmark (RISK-01)**:
   - Measured loop iterations over a 0.5-second window:
     - `(accept-process-output proc 0.02)` on a terminated process executed **279,426 iterations** (**558,852 iters/sec**, 100% CPU core utilization).
     - `(accept-process-output nil 0.02)` executed **25 iterations** (**50.0 iters/sec**, proper OS sleep).
     - Asynchronous pipe sentinel fired cleanly within 0.060s without CPU starvation.

---

## 2. Logic Chain

1. From Observation 1, `kargu-tool-execution--validate-gate` checks `modes` only if defined on `definition`. Because production mutating tools do not define `:policy`, the gate returns `:ok` in `ask` and `plan` modes. Because `edit_file` checks the global session mode rather than context mode, files are mutated on disk in `ask` and `plan` modes whenever the session is `agent`. This directly breaks Contract 5, Section 5.5 and ARCH-02.
2. From Observation 2, `kargu-tool-gate-execute` predicates claiming an approval token on `(and needs-appr approval)`. Because `needs-appr` is nil for all non-bash tools, any approval token passed to `kargu-tool-gate-execute` remains unconsumed (`claimed-p = nil`) and can be replayed repeatedly. This breaks ARCH-03 and Contract 5, Section 5.6.
3. From Observation 3, `kargu-tool-registry--policy-p` rejects `:needs-approval-p`, making it impossible to fix Observation 2 via tool policies without modifying the policy validation contract.
4. From Observations 4 and 5, policy revision checking and draining state enforcement operate correctly and meet architectural requirements.
5. From Observations 6 and 7, Package F (process tree cancellation via negative PID process group signaling and non-starving wait loops via `(accept-process-output nil 0.02)`) resolves RISK-01 empirically with verified zero orphan leaks and zero CPU spin.
6. Therefore, while Package F is robust, Package D contains critical security and invariant bypasses requiring remediation.

---

## 3. Caveats

- We did NOT modify any implementation code in accordance with the `review-only` challenger directive.
- All testing was performed using batch Emacs invocations on Linux. Negative-PID process group signaling was verified on Linux; non-POSIX platforms (`windows-nt`) fall back to single process kill as noted in `kargu/tools/process.el`.

---

## 4. Conclusion

**Verdict: REQUEST_CHANGES**

Package D must be remediated:
1. In `kargu/tools/execution.el`, `kargu-tool-execution--validate-gate` must check `kargu-loop-mutating-tools` and reject calls when `cur-mode` is not `'agent` (or production tools must register `:policy '(:modes (agent))`).
2. In `kargu/tools/execution.el`, whenever `:approval` is passed to `kargu-tool-gate-execute`, the token MUST be claimed via `kargu-tool-approval-claim` regardless of `needs-appr`.
3. In `kargu/tools/registry.el`, `kargu-tool-registry--policy-p` must allow `:needs-approval-p`.

Package F is approved.

---

## 5. Verification Method

To verify the findings independently:

1. **Verify Mode Gating Bypass (Disk Mutation in Ask Mode)**:
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
             (message "DISK CONTENT: %S" (with-temp-buffer (insert-file-contents temp-file) (buffer-string))))
         (when (file-exists-p temp-file) (delete-file temp-file)))))'
   ```
   *Expected defect behavior*: Result reports `APPLIED`, file on disk is modified to `MUTATED!`.

2. **Verify Approval Token Replay on Non-Bash Tools**:
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
         (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)
         (message "Claimed after exec 1: %S" (kargu-tool-approval-claimed-p token))
         (kargu-tool-gate-execute-sync reg ctx "op" args :approval token)
         (message "Claimed after exec 2: %S (executed=%d)" (kargu-tool-approval-claimed-p token) executed))))'
   ```
   *Expected defect behavior*: Claimed remains `nil`, executed equals `2` (replayed successfully).

3. **Verify RISK-01 Dead Process CPU Spin vs Proper Sleep**:
   ```bash
   emacs -Q --batch -L . --eval '(progn
     (require (quote package)) (package-initialize) (require (quote kargu))
     (let ((proc (make-process :name "d" :command (quote ("sh" "-c" "exit 0")) :noquery t)))
       (while (process-live-p proc) (accept-process-output nil 0.01))
       (let ((i-proc 0) (t0 (float-time)))
         (while (< (- (float-time) t0) 0.5) (accept-process-output proc 0.02) (cl-incf i-proc))
         (message "Dead proc iterations: %d (%.0f/s)" i-proc (* 2.0 i-proc)))
       (let ((i-nil 0) (t0 (float-time)))
         (while (< (- (float-time) t0) 0.5) (accept-process-output nil 0.02) (cl-incf i-nil))
         (message "Nil iterations: %d (%.0f/s)" i-nil (* 2.0 i-nil)))
       (delete-process proc)))'
   ```
   *Expected behavior*: Dead proc ~280k iterations/0.5s; Nil ~25 iterations/0.5s.
