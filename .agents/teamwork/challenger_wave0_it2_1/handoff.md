# Handoff Report: Wave 0 Iteration 2 Empirical Challenge

**Date**: 2026-10-21T21:53:45Z  
**Agent**: `challenger_wave0_it2_1` (Wave 0 Iteration 2 Empirical Challenger)  
**Milestone**: Wave 0 Iteration 2 Acceptance Gate  
**Verdict**: **APPROVE**

---

## 1. Observation

1. **Exact Challenger Verification Script Execution**:
   - Command:
     ```bash
     emacs -Q --batch -L . -l /dev/stdin << 'EOF'
     (require 'cl-lib)
     (require 'kargu/files)
     (require 'kargu/application/coordinator)

     ;; Check 1: In-flight request claim bypass
     (let ((app (kargu-application-create :status :idle :generation 1)))
       (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
         (kargu-application-set-active-request req app)
         (let ((claim (kargu-application-claim app :no-error t)))
           (cl-assert (null claim) nil "BUG-04: Claim should be rejected while request is in-flight!"))))

     ;; Check 2: Cross-app release rejection
     (let ((app-a (kargu-application-create :status :idle :generation 0))
           (app-b (kargu-application-create :status :idle :generation 0)))
       (let ((c-a (kargu-application-claim app-a))
             (c-b (kargu-application-claim app-b)))
         (cl-assert (null (kargu-application-release app-a c-b)) nil
                    "BUG-06: Claim from App B must NOT release App A!")))

     (message "All challenge assertions verified.")
     EOF
     ```
   - Result: Exit code 0.
   - Verbatim stdout: `All challenge assertions verified.`

2. **Remote Tramp Non-Blocking Evaluation**:
   - Command:
     ```elisp
     (let* ((t0 (current-time))
            (res1 (kargu-file-current-revision "/ssh:user@remote:/path"))
            (res2 (kargu-file-current-revision "/sudo:root@localhost:/etc/shadow"))
            (res3 (kargu-file-current-revision "/scp:remote.domain.org:/home/user/test.txt"))
            (res4 (kargu-file-current-revision "/sshx:deploy@192.168.1.100:/opt/app"))
            (elapsed (float-time (time-subtract (current-time) t0))))
       (cl-assert (null res1)) (cl-assert (null res2))
       (cl-assert (null res3)) (cl-assert (null res4))
       (cl-assert (< elapsed 0.1))
       (message "Remote Tramp checks passed in %.6f seconds" elapsed))
     ```
   - Result: Exit code 0.
   - Verbatim stdout: `Remote Tramp checks passed in 0.031389 seconds`

3. **Symlink and Circular Reference Resolution**:
   - Dangling symlink: `(kargu-file-current-revision dangling)` evaluated to `nil`.
   - Modifying target file through symlink updated `(kargu-file-current-revision symlink)` to match new target bytes and modification timestamp.
   - Circular symlink loop (`circ-a -> circ-b` and `circ-b -> circ-a`): `(kargu-file-current-revision circ-a)` evaluated to `nil` in <0.001s without infinite loop or unhandled error.

4. **Application Context Unit Test Suite (`tests/test-application-context.el`)**:
   - Command:
     ```bash
     emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-application-context))" -f ert-run-tests-batch-and-exit
     ```
   - Result: Exit code 0.
   - Verbatim stdout:
     ```
     Ran 9 tests, 9 results as expected, 0 unexpected (2026-10-21 21:50:43+0000, 0.120119 sec)
     ```

5. **Full Repository ERT Test Suite**:
   - Command:
     ```bash
     emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
     ```
   - Result: Exit code 0.
   - Verbatim stdout:
     ```
     Ran 953 tests, 953 results as expected, 0 unexpected (2026-10-21 21:51:50+0000, 43.564675 sec)
     ```

6. **Byte-Compilation and Checkdoc Verification**:
   - Command:
     ```bash
     emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (setq byte-compile-error-on-warn t))" -f batch-byte-compile kargu/application/coordinator.el kargu/files.el tests/test-application-context.el && rm -f kargu/application/coordinator.elc kargu/files.elc tests/test-application-context.elc
     ```
   - Result: Exit code 0, 0 compiler warnings, 0 compiler errors.
   - Command:
     ```bash
     emacs -Q --batch --eval "(progn (require 'checkdoc) (checkdoc-file \"kargu/application/coordinator.el\") (checkdoc-file \"kargu/files.el\") (checkdoc-file \"tests/test-application-context.el\"))"
     ```
   - Result: Exit code 0, 0 checkdoc warnings.

7. **TLC Formal Model Verification**:
   - `bash proof/run_tlc.sh --mode`: Exit code 0 (`20179 states generated, 5958 distinct states found, 0 states left on queue. Finished in 00s`).
   - `bash proof/run_tlc.sh --edit-transaction`: Exit code 0 (`425 states generated, 160 distinct states found, 0 states left on queue. Finished in 00s`).

8. **Repository Hygiene**:
   - `find . -name "*.elc"`: 0 matches found.
   - `git status --porcelain skills.md .gitignore`: 0 matches found (files untouched).

---

## 2. Logic Chain

1. **Pre-Check Invariant Guarding (Observation 1, 4)**:
   - In `kargu/application/coordinator.el:208`, `kargu-application-claim` checks `(or (kargu-application-active-run target) (kargu-application-work-active-p target))` prior to executing `(cl-incf (kargu-application-generation target))`.
   - Because generation is preserved when a request is active, `kargu-logical-request-live-p` accurately matches `req`'s generation.
   - Consequently, in-flight requests consistently block execution claims, and generation numbers are not corrupted by failed claims (BUG-04, BUG-05).

2. **Instance-Scoped Token Binding (Observation 1, 4)**:
   - In `kargu/application/coordinator.el:234`, `kargu-application-release` enforces `(eq (kargu-application-claim-app claim) target)`.
   - When Application A and Application B both issue claims with identical default `run-1`, Claim B contains `:app app-b` while target is `app-a`.
   - Because pointer equality fails, Claim B is strictly prohibited from releasing Application A (BUG-06).

3. **Early Tramp Path Dismissal (Observation 2)**:
   - In `kargu/files.el:151`, `(not (file-remote-p path))` is tested prior to calling `(file-exists-p path)`.
   - Remote Tramp paths bypass the local filesystem branch entirely and immediately yield `nil` in <0.035s without initiating network handshakes or hanging (BUG-01).

4. **Canonical Resolution and Symlink Freshening (Observation 3)**:
   - In `kargu/files.el:164-168`, `(file-truename target)` canonicalizes symlink paths.
   - `(file-exists-p truename)` verifies that the target actually exists, correctly returning `nil` for dangling links (BUG-02).
   - Calling `file-attributes` on `truename` reads the canonical target's inode, bytes, and modification timestamp, ensuring file modifications reflect dynamically (BUG-03).
   - Wrapped in `condition-case`, circular symlinks safely return `nil` without crashing or entering infinite loops.

5. **Full Regression and Project Invariant Adherence (Observation 5, 6, 7, 8)**:
   - All 953 ERT tests passed with 0 failures.
   - Strict byte-compilation and checkdoc produced zero warnings.
   - Both TLA+ specifications model-checked cleanly.
   - Repository governance constraints are fully respected.

---

## 3. Caveats

No caveats. All target defects from Wave 0 Iteration 1 have been directly, independently, and empirically tested under hostile edge cases and verified to be completely resolved.

---

## 4. Conclusion

The Wave 0 Iteration 2 remediation satisfies all acceptance criteria, contract boundaries, and architectural invariants for Wave 0.

- **Verdict**: **APPROVE**
- **Action**: Proceed to Wave 1 (Package A, Package B, Package C).

---

## 5. Verification Method

To independently reproduce this verification:

1. **Challenger Invariant Script**:
   ```bash
   emacs -Q --batch -L . -l /dev/stdin << 'EOF'
   (require 'cl-lib)
   (require 'kargu/files)
   (require 'kargu/application/coordinator)
   (let ((app (kargu-application-create :status :idle :generation 1)))
     (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
       (kargu-application-set-active-request req app)
       (let ((claim (kargu-application-claim app :no-error t)))
         (cl-assert (null claim) nil "BUG-04 failed"))))
   (let ((app-a (kargu-application-create :status :idle :generation 0))
         (app-b (kargu-application-create :status :idle :generation 0)))
     (let ((c-a (kargu-application-claim app-a))
           (c-b (kargu-application-claim app-b)))
       (cl-assert (null (kargu-application-release app-a c-b)) nil "BUG-06 failed")))
   (message "VERIFIED")
   EOF
   ```
   *Expected*: Prints `VERIFIED` and exits with code 0.

2. **ERT Suite**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   ```
   *Expected*: `Ran 953 tests, 953 results as expected, 0 unexpected`.

3. **TLC Proofs**:
   ```bash
   bash proof/run_tlc.sh --mode
   bash proof/run_tlc.sh --edit-transaction
   ```
   *Expected*: Both exit with 0.

Invalidation condition: Any non-zero exit code or assertion failure invalidates this approval.
