# Handoff Report: Wave 0 Empirical Challenge

**Date**: 2026-10-21T21:05:00Z  
**Agent**: `challenger_wave0_1` (Wave 0 Empirical Challenger 1)  
**Verdict**: **REQUEST_CHANGES**

---

## 1. Observation

1. **`kargu/application/coordinator.el:207-212`**:
   ```elisp
   (let* ((target (kargu-application-context app))
          (run-id (or (plist-get plist :run-id)
                      (format "run-%d" (cl-incf (kargu-application-generation target)))))
          (session-id (plist-get plist :session-id))
          (no-error (plist-get plist :no-error)))
     (if (or (kargu-application-active-run target)
             (kargu-application-work-active-p target))
   ```
   Direct execution in batch Emacs:
   ```elisp
   (let ((app (kargu-application-create :status :idle :generation 1)))
     (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
       (kargu-application-set-active-request req app)
       (kargu-application-claim app :no-error t)))
   ```
   Result:
   `#s(kargu-application-claim "claim-2" #s(kargu-application :running "run-2" #s(kargu-logical-request "req-1" 1 nil nil :in-flight nil nil nil) 2 nil nil) "run-2" nil)`
   The claim succeeded even though an active request was `:in-flight`.

2. **`kargu/application/coordinator.el:231-236`**:
   ```elisp
   (if (and current
            (or (eq current claim)
                (and (kargu-application-claim-p claim)
                     (equal (kargu-application-claim-run-id claim) current))
                (and (stringp claim) (equal claim current))))
   ```
   Direct execution in batch Emacs:
   ```elisp
   (let ((app-a (kargu-application-create :status :idle :generation 0))
         (app-b (kargu-application-create :status :idle :generation 0)))
     (let ((c-a (kargu-application-claim app-a))
           (c-b (kargu-application-claim app-b)))
       (kargu-application-release app-a c-b)))
   ```
   Result: `t`. `(kargu-application-active-run app-a)` became `nil`. `c-b` belonging to `app-b` released `app-a`.

3. **`kargu/files.el:146-160`**:
   ```elisp
   (let ((target (cond
                  ((bufferp path)
                   (and (buffer-live-p path) (buffer-file-name path)))
                  ((and (stringp path) (file-exists-p path))
                   path)
                  ...)))
     (when (and (stringp target)
                (not (string-empty-p (string-trim target)))
                (not (file-remote-p target)))
   ```
   Execution with `(kargu-file-current-revision "/ssh:user@nohost:/path")`:
   `file-exists-p` at line 149 triggers Tramp connection before `file-remote-p` at line 159 can prevent it. Batch execution hangs waiting for Tramp connection (`File error: Tramp failed to connect...`).

4. **`kargu/files.el:161-167`**:
   ```elisp
   (let ((attrs (file-attributes target)))
     (when attrs
       (kargu-file--make-revision ...)))
   ```
   - For dangling symlink: `(file-attributes dangling-symlink)` returns `#s(kargu-file-revision ...)` with the symlink's `lstat` data instead of `nil`.
   - For valid symlink: updating target file does not change `(kargu-file-current-revision symlink)`.

---

## 2. Logic Chain

1. **Premature Generation Advance (Observation 1)**:
   - Line 207 calls `(cl-incf (kargu-application-generation target))` unconditionally when `:run-id` is omitted.
   - `kargu-application-work-active-p` delegates to `(kargu-logical-request-live-p req (kargu-application-generation target))`.
   - Because generation was incremented before the check, `(= (kargu-logical-request-generation req) current-generation)` evaluates `(= 1 2)`, returning `nil`.
   - Therefore, `work-active-p` returns `nil` and the claim is granted, violating the single-active-work invariant (ARCH-01).

2. **Foreign Claim Release (Observation 2)**:
   - `kargu-application-claim` attaches `:app target` to the returned claim record.
   - `kargu-application-release` checks `(equal (kargu-application-claim-run-id claim) current)` but omits `(eq (kargu-application-claim-app claim) target)`.
   - Because instances starting at generation 0 both generate `"run-1"` by default, claim `c-b` from instance $B$ satisfies the condition on instance $A$.
   - Therefore, a foreign claim releases an unrelated application instance, violating ARCH-01 and ARCH-12.

3. **Remote Tramp Blocking (Observation 3)**:
   - `file-exists-p` on a remote path initiates Tramp network I/O.
   - Line 149 runs `file-exists-p` before line 159 checks `file-remote-p`.
   - Therefore, any remote path blocks Emacs synchronously.

4. **Symlink Resolution (Observation 4)**:
   - `file-attributes` in Emacs uses `lstat`.
   - For dangling symlinks, `lstat` succeeds, so a revision record is returned for a non-existent target.
   - For file symlinks, changes to the target do not alter the symlink's `lstat` mtime/size.
   - Therefore, revisions obtained via symlink are stale and do not reflect disk changes.

---

## 3. Caveats

- All standard ERT tests (948/948) pass because they did not test the specific interleaving of active logical requests without explicit `:run-id`, nor did they test cross-app release with default identical run IDs.
- Byte-compilation is clean across all files; the defects are logical and semantic edge cases.

---

## 4. Conclusion

The current Wave 0 implementation has critical invariant gaps that would compromise Wave 1 (Package A and Package B).
- **Verdict**: **REQUEST_CHANGES**
- **Actionable Fixes Required**:
  1. In `kargu/application/coordinator.el:kargu-application-claim`: Check `(or (kargu-application-active-run target) (kargu-application-work-active-p target))` *before* incrementing `generation` or generating `run-id`.
  2. In `kargu/application/coordinator.el:kargu-application-release`: Add `(eq (kargu-application-claim-app claim) target)` when `(kargu-application-claim-p claim)`.
  3. In `kargu/files.el:kargu-file-current-revision`: Check `(file-remote-p path)` *before* any `file-exists-p` call; and use `(file-truename target)` (with `(file-exists-p (file-truename target))`) before calling `file-attributes`.

---

## 5. Verification Method

Run the following command from the project root:

```bash
emacs -Q --batch -L . -l /dev/stdin << 'EOF'
(require 'kargu/files)
(require 'kargu/application/coordinator)

;; Check 1: In-flight request claim bypass
(let ((app (kargu-application-create :status :idle :generation 1)))
  (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
    (kargu-application-set-active-request req app)
    (let ((claim (kargu-application-claim app :no-error t)))
      (assert (null claim) nil "BUG-04: Claim should be rejected while request is in-flight!"))))

;; Check 2: Cross-app release rejection
(let ((app-a (kargu-application-create :status :idle :generation 0))
      (app-b (kargu-application-create :status :idle :generation 0)))
  (let ((c-a (kargu-application-claim app-a))
        (c-b (kargu-application-claim app-b)))
    (assert (null (kargu-application-release app-a c-b)) nil
            "BUG-06: Claim from App B must NOT release App A!")))

(message "All challenge assertions verified.")
EOF
```

Invalidation condition: If the above command exits with code 0 without assertion failures, the issues have been successfully resolved.
