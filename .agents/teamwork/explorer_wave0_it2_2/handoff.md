# Handoff Report: Wave 0 Revision & Symlinks Remediation

**Author**: `explorer_wave0_it2_2` (Wave 0 Remediation Explorer for Revision & Symlinks)  
**Date**: 2026-10-21  
**Milestone**: Wave 0 Iteration 2  
**Target Files**: `kargu/files.el`, `tests/test-file-window.el`  
**Detailed Report**: `.agents/teamwork/explorer_wave0_it2_2/revision_remediation_report.md`

---

## 1. Observation

1. **`kargu/files.el:146-160` (Premature `file-exists-p`)**:
   ```elisp
   (let ((target (cond
                  ((bufferp path)
                   (and (buffer-live-p path) (buffer-file-name path)))
                  ((and (stringp path) (file-exists-p path))
                   path)
                  ((and (stringp path) (get-buffer path))
                   (let ((buf (get-buffer path)))
                     (and buf (buffer-live-p buf) (buffer-file-name buf))))
                  ((stringp path)
                   path)
                  (t nil))))
     (when (and (stringp target)
                (not (string-empty-p (string-trim target)))
                (not (file-remote-p target)))
   ```
   Executing `(file-exists-p "/ssh:user@nohost:/path")` in batch Emacs yields:
   ```
   File error: Tramp failed to connect.  If this happens repeatedly, try
       ‘M-x tramp-cleanup-this-connection’
   file-exists-p caught: (file-error "Tramp failed to connect...")
   ```
   Line 149 executes `file-exists-p` before line 159 checks `file-remote-p`, triggering synchronous Tramp network I/O outside `condition-case`.

2. **`kargu/files.el:160-167` (Dangling Symlinks and Target Modification Blindness)**:
   ```elisp
   (condition-case nil
       (let ((attrs (file-attributes target)))
         (when attrs
           (kargu-file--make-revision ...)))
     (error nil))
   ```
   Direct reproduction on dangling and modified symlinks:
   - For dangling symlink `dangling`:
     `(kargu-file-current-revision dangling)` returned:
     `#s(kargu-file-revision 108562377 66310 72 (27353 10992 623869 346000))`
     instead of `nil`.
   - For valid symlink `symlink` to `real-file`:
     After updating `real-file` on disk from 5 bytes to 24 bytes,
     `(equal (kargu-file-current-revision symlink) rev-before)` returned `t`.

3. **Remediated Function Execution**:
   Evaluating the remediated `kargu-file-current-revision` across all 12 edge cases (remote bypass, dangling symlink, symlink update, killed buffer, scratch buffer, cycle, etc.) exited cleanly with code 0.

4. **Hygiene & Standards**:
   - `checkdoc` on candidate code reported zero warnings.
   - `byte-compile-file` with `byte-compile-error-on-warn t` produced zero warnings.
   - All 17 tests in `tests/test-file-window.el` passed with candidate function.

---

## 2. Logic Chain

1. **Remote Tramp Bypass (BUG-01)**:
   - Observation 1 demonstrates that `file-exists-p` on Tramp syntax (`/ssh:...`) invokes Tramp network handlers.
   - In current `kargu/files.el`, line 149 runs `(file-exists-p path)` unconditionally for any string before line 159 checks `(file-remote-p target)`.
   - Therefore, passing a remote path initiates network operations and throws an unhandled `file-error`.
   - Moving `(not (file-remote-p path))` before any `file-exists-p` or `file-truename` call guarantees zero Tramp network attempts.

2. **Dangling Symlink Revisions (BUG-02)**:
   - Observation 2 demonstrates that `(file-attributes target)` in Emacs uses POSIX `lstat(2)`.
   - When `target` is a dangling symlink, `lstat` succeeds on the symlink file itself, returning its own inode, mode, and size.
   - Therefore, a non-nil revision struct is constructed for a missing target file, violating the contract ("Return nil if PATH is absent, not visiting a file on disk, or unreadable").
   - Resolving `target` with `truename = (file-truename target)` and verifying `(file-exists-p truename)` causes dangling symlinks to return `nil`.

3. **Symlink Target Modification Detection (BUG-03)**:
   - Observation 2 demonstrates that modifying `real-file` leaves the symlink file's own `lstat` mtime and size unchanged.
   - Calling `file-attributes` directly on `target` (the symlink path) produces identical revisions before and after modifying the underlying file.
   - Calling `(file-attributes truename)` inspects the canonical underlying file, reflecting changes to byte size and mtime immediately.

4. **Verification Completeness**:
   - Observations 3 and 4 verify that all edge cases (circular links, killed buffers, directories, unsaved buffers) pass cleanly with zero checkdoc and byte-compilation warnings.

---

## 3. Caveats

- Coordinator application claim defects (BUG-04, BUG-05, BUG-06 in `kargu/application/coordinator.el`) are scoped to peer worker `explorer_wave0_it2_1` and are not part of this report.
- Symlinks pointing directly to remote Tramp paths are resolved to quoted paths (`/:/ssh:...`) by `file-truename`; defensive checks ensure they evaluate to `nil` without network connection.
- No other caveats.

---

## 4. Conclusion

The defects in `kargu-file-current-revision` (BUG-01, BUG-02, BUG-03) are completely resolved by:
1. Reordering string target resolution to guard against empty, whitespace, and remote paths before calling `file-exists-p`.
2. Resolving `(file-truename target)` and checking `(file-exists-p truename)` before calling `file-attributes`.

### Actionable Code for Implementation in `kargu/files.el:142-169`:

```elisp
(defun kargu-file-current-revision (path)
  "Return `kargu-file-revision' for PATH on disk or in buffer, or nil.
PATH may be a file path string or a buffer.  Return nil if PATH is absent,
not visiting a file on disk, or unreadable."
  (let ((target (cond
                 ((bufferp path)
                  (and (buffer-live-p path) (buffer-file-name path)))
                 ((and (stringp path)
                       (not (string-empty-p (string-trim path)))
                       (not (file-remote-p path)))
                  (cond
                   ((file-exists-p path)
                    path)
                   ((and (get-buffer path)
                         (buffer-live-p (get-buffer path)))
                    (buffer-file-name (get-buffer path)))
                   (t path)))
                 (t nil))))
    (when (and (stringp target)
               (not (string-empty-p (string-trim target)))
               (not (file-remote-p target)))
      (condition-case nil
          (let ((truename (file-truename target)))
            (when (and (stringp truename)
                       (not (file-remote-p truename))
                       (file-exists-p truename))
              (let ((attrs (file-attributes truename)))
                (when attrs
                  (kargu-file--make-revision
                   :inode (file-attribute-inode-number attrs)
                   :device (file-attribute-device-number attrs)
                   :bytes (file-attribute-size attrs)
                   :mtime (file-attribute-modification-time attrs))))))
        (error nil)))))
```

---

## 5. Verification Method

Run the following command from the repository root:

```bash
emacs -Q --batch -L . -l /dev/stdin << 'EOF'
(require 'ert)
(require 'kargu/files)

;; Test 1: Remote Tramp bypass
(let ((called nil)
      (orig (symbol-function 'file-exists-p)))
  (cl-letf (((symbol-function 'file-exists-p)
             (lambda (f) (when (string-prefix-p "/ssh:" f) (setq called t)) (funcall orig f))))
    (cl-assert (null (kargu-file-current-revision "/ssh:nobody@nohost:/path/file.txt")))
    (cl-assert (null called) nil "BUG-01: file-exists-p was called on remote path!")))

;; Test 2 & 3: Symlinks
(let* ((dir (make-temp-file "kargu-test-verif-" t))
       (real-file (expand-file-name "actual.txt" dir))
       (link-file (expand-file-name "link.txt" dir))
       (dangling (expand-file-name "dangling.txt" dir)))
  (unwind-protect
      (progn
        (with-temp-file real-file (insert "hello world"))
        (make-symbolic-link real-file link-file)
        (make-symbolic-link (expand-file-name "absent.txt" dir) dangling)

        ;; BUG-02
        (cl-assert (null (kargu-file-current-revision dangling)) nil
                   "BUG-02: Dangling symlink must return nil!")

        ;; BUG-03
        (let ((rev1 (kargu-file-current-revision link-file)))
          (cl-assert (kargu-file-revision-p rev1))
          (with-temp-file real-file (insert "updated and modified content"))
          (let ((rev2 (kargu-file-current-revision link-file)))
            (cl-assert (kargu-file-revision-p rev2))
            (cl-assert (not (equal rev1 rev2)) nil
                       "BUG-03: Symlink did not reflect target file modification!"))))
    (delete-directory dir t)))

(message "All revision remediation assertions verified successfully.")
EOF
```

**Invalidation Conditions**:
- If `kargu-file-current-revision` on `/ssh:nobody@nohost:/path` calls `file-exists-p` or triggers Tramp network connection.
- If `kargu-file-current-revision` on a dangling symlink returns non-nil.
- If `kargu-file-current-revision` on a symlink returns equal revisions after the underlying target file is modified on disk.
