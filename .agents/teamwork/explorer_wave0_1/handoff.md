# Handoff Report: Wave 0 Revision API

**Agent**: `teamwork_preview_explorer_wave0_1`  
**Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_1`  
**Date**: 2026-10-21  
**Handoff Type**: Hard (Investigation & Design Complete)  
**Detailed Report**: [wave0_revision_report.md](file:///home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_1/wave0_revision_report.md)

---

## 1. Observation

1. **`kargu-file--file-revision` definition in `kargu/files.el:142-150`**:
   ```elisp
   (defun kargu-file--file-revision (path)
     "Capture PATH's filesystem identity, size and content modification time."
     (let ((attributes (file-attributes path)))
       (unless attributes (error "File disappeared while reading its snapshot"))
       (kargu-file--make-revision
        :inode (file-attribute-inode-number attributes)
        :device (file-attribute-device-number attributes)
        :bytes (file-attribute-size attributes)
        :mtime (file-attribute-modification-time attributes))))
   ```
   Directly observed: `kargu-file--file-revision` is private (`--`), strictly reads disk attributes, and signals unhandled `error` `"File disappeared while reading its snapshot"` if `attributes` is `nil`.

2. **Internal calls in `kargu/files.el:168, 184`**:
   `kargu-file--disk-excerpt` uses `kargu-file--file-revision` before and after reading chunks:
   ```elisp
   (let* ((before (kargu-file--file-revision path)) ...)
     ...
     (unless (equal before (kargu-file--file-revision path))
       (error "File changed while its snapshot was being read")))
   ```

3. **Cross-boundary private call in `kargu/tools/diff/track.el:44-48`**:
   ```elisp
   (defun kargu-diff--disk-revision (path)
     "Return `kargu-file-revision' for PATH on disk, or nil when absent."
     (when (file-exists-p path)
       (ignore-errors (kargu-file--file-revision path))))
   ```
   Directly observed: `track.el` accesses private symbol `kargu-file--file-revision` across module boundaries and masks potential errors via `(ignore-errors ...)`.

4. **Codebase-wide search for `kargu-file--` symbols**:
   A global grep across the repository revealed `track.el:47` is the **only** production call to any `kargu-file--` symbol outside `kargu/files.el` and `kargu/files/`. All other occurrences are inside `kargu/files.el`, `kargu/files/async.el`, or unit tests in `tests/test-file-window.el`.

5. **Test suite baseline**:
   Running `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit` yielded:
   `Ran 942 tests, 942 results as expected, 0 unexpected`.

6. **In-memory verification of proposed replacement**:
   Executed in batch Emacs:
   - On existing file (`kargu/files.el`): `#s(kargu-file-revision ...)` returned.
   - On buffer visiting existing file: `#s(kargu-file-revision ...)` returned.
   - On non-existent file: `nil` returned.
   - On scratch buffer: `nil` returned.
   - On full ERT suite (942 tests) with proposed override: `942 passed, 0 failed`.
   - `checkdoc-defun`: 0 warnings, 0 errors.
   - `byte-compile-file` with `(setq byte-compile-error-on-warn t)`: 0 warnings, 0 errors.

---

## 2. Logic Chain

1. **Step 1**: From Observation 1 and Observation 3, `kargu/tools/diff/track.el` depends on an internal private symbol (`kargu-file--file-revision`) of `kargu/files.el`. This violates modular encapsulation and directly breaches the boundary requirements documented in `parallel-plan.md` lines 75-80.
2. **Step 2**: From Observation 4, `track.el:47` is the only external caller of `kargu-file--file-revision` (and indeed the only cross-module caller of any `kargu-file--` symbol in production). Therefore, introducing a public API in `kargu/files.el` and updating `track.el` completely resolves all file-layer cross-boundary violations.
3. **Step 3**: `parallel-plan.md` Section 3 mandates: "Dalga 0'da B'nin çapraz private çağrısını kaldırabilmesi için koordinatör `kargu/files.el` içinde mevcut revision okuyucusunu public, doğrulanan `kargu-file-current-revision` sınırıyla açabilir. Yeni disk okuma motoru veya ikinci revision tipi oluşturmaz."
4. **Step 4**: To satisfy this without creating a second revision type or disk engine, `kargu-file-current-revision` should:
   - Accept `path` (file path string or buffer).
   - Resolve to disk file if live buffer or buffer name is passed.
   - Catch absent or unreadable targets and return `nil`.
   - Return the existing `kargu-file-revision` struct.
5. **Step 5**: To avoid regressing internal callers in `kargu/files.el` (`kargu-file--disk-excerpt`), `kargu-file--file-revision` is retained as an internal helper that delegates to `(kargu-file-current-revision path)`, signaling `"File disappeared while reading its snapshot"` if `nil`.
6. **Step 6**: From Observation 6, this design compiles cleanly with `byte-compile-error-on-warn t`, satisfies checkdoc completely, and passes all 942 ERT tests.

---

## 3. Caveats

- **Scope boundary**: This investigation is read-only. No edits were made to `kargu/files.el` or `kargu/tools/diff/track.el`. The implementation must be executed by the Wave 0 Worker / Coordinator.
- **Buffer dirtiness vs disk revision**: `kargu-file-revision` tracks disk metadata (`inode`, `device`, `bytes`, `mtime`). Buffer unsaved state is tracked by callers (e.g. `track.el` checks `buffer-chars-modified-tick` and text). The proposed `kargu-file-current-revision` faithfully returns the disk revision for the visited file, which matches how `track.el` uses `:post-disk-revision`.
- **Remote files**: Remote Tramp paths are explicitly rejected (`nil` returned), consistent with Kargu's local file invariants.

---

## 4. Conclusion

1. Expose public `kargu-file-current-revision` in `kargu/files.el` with signature `(kargu-file-current-revision path)`.
2. Refactor private `kargu-file--file-revision` to delegate to `kargu-file-current-revision`.
3. Update `kargu/tools/diff/track.el` line 44 `kargu-diff--disk-revision` to call `(kargu-file-current-revision path)` directly.
4. With this change, Package B in Wave 1 can proceed without any cross-boundary private file dependencies.

---

## 5. Verification Method

To verify the implementation once applied by the worker:

1. **Checkdoc validation**:
   ```bash
   emacs -Q --batch -L . --eval '
   (require '\''checkdoc)
   (with-current-buffer (find-file-noselect "kargu/files.el")
     (checkdoc-current-buffer t))
   '
   ```
   Expected: 0 errors reported.

2. **Byte-compilation with zero warnings**:
   ```bash
   emacs -Q --batch -L . --eval '
   (setq byte-compile-error-on-warn t)
   (byte-compile-file "kargu/files.el")
   (byte-compile-file "kargu/tools/diff/track.el")
   (delete-file "kargu/files.elc")
   (delete-file "kargu/tools/diff/track.elc")
   '
   ```
   Expected: Exit code 0, no warnings.

3. **Full test suite execution**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   ```
   Expected: 942/942 passed, 0 failures, 0 unexpected.

4. **Verify zero private cross-boundary calls**:
   ```bash
   grep -rn "kargu-file--" kargu/tools/
   ```
   Expected: 0 matches.
