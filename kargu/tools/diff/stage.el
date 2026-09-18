;;; kargu/tools/diff/stage.el --- Shadow buffer creation and staging logic -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shadow buffer management and proposal staging logic.
;; Separated from `kargu/tools/diff' for single responsibility.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/tools/diff/track)

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)
(defvar kargu-diff-after-apply-hook)

(defvar kargu-diff--current-file nil
  "Absolute path of the file reported by `kargu-diff-after-apply-hook'.
Dynamically bound while the hook runs.")

(declare-function kargu-diff--apply-interactive "kargu/tools/diff/review" (path buf-a original new-content exists callback))
(declare-function kargu-diff--sessions "kargu/tools/diff/review" ())
(declare-function kargu-diff--session-live-p "kargu/tools/diff/review" (session))
(declare-function kargu-diff--reap-stale "kargu/tools/diff/review" (path))
(declare-function kargu-to-int "kargu/core" (value &optional default))
(defvar kargu-diff--sessions)

;;;; Helpers --------------------------------------------------------------

(defun kargu-diff--resolve (path)
  "Expand PATH (absolute or project-relative) to an absolute name
and assert that it is strictly within the project root."
  (unless (and (stringp path) (not (string-empty-p (string-trim path))))
    (error "path must be a non-empty string"))
  (let* ((root (kargu-permission-project-root))
          (abs (if (file-name-absolute-p path)
                   (expand-file-name path)
                 (expand-file-name path root))))
    (kargu-permission-assert-within-project abs root "file")))

(defalias 'kargu-diff--to-int #'kargu-to-int)

(defun kargu-diff--count-literal (haystack needle)
  "Count non-overlapping occurrences of NEEDLE in HAYSTACK."
  (if (or (not (stringp haystack))
          (not (stringp needle))
          (string-empty-p needle))
      0
    (with-temp-buffer
      (insert haystack)
      (goto-char (point-min))
      (let ((count 0))
        (while (search-forward needle nil t)
          (setq count (1+ count)))
        count))))

(defun kargu-diff--replace-first (haystack old new)
  "Replace the first literal occurrence of OLD in HAYSTACK with NEW."
  (with-temp-buffer
    (insert haystack)
    (goto-char (point-min))
    (if (not (search-forward old nil t))
        haystack
      (replace-match new t t)
      (buffer-string))))

(defun kargu-diff--file-text (path)
  "Return the text of PATH from its visiting buffer, or from disk."
  (let ((buf (find-buffer-visiting path)))
    (cond
     ((buffer-live-p buf)
      (with-current-buffer buf (buffer-string)))
     ((file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))
     (t nil))))

(defun kargu-diff-apply-replace (file-path old-string new-string &optional callback)
  "Replace the unique OLD-STRING in FILE-PATH with NEW-STRING.
The replacement is staged through `kargu-diff-apply-proposal'
(shadow buffer + ediff).  Signal an error when OLD-STRING is
missing or not unique so the model can re-read and retry."
  (unless (and (stringp old-string) (not (string-empty-p old-string)))
    (error "old_string must be a non-empty string"))
  (unless (stringp new-string)
    (error "new_string must be a string"))
  (let ((path (kargu-diff--resolve file-path)))
    (unless (or (file-exists-p path) (find-buffer-visiting path))
      (error (concat "No such file: '%s'\n"
                     "  - Attempted file: '%s'\n"
                     "  - Allowed project root: '%s'\n"
                     "  - Reason: The target file does not exist within the permitted workspace boundary.\n"
                     "  - Guidance: Use `write_file' to create a new file, or use `find_files' to check existing files inside '%s'.")
             path file-path (kargu-permission-project-root) (kargu-permission-project-root)))
    (when (file-directory-p path)
      (error (concat "Invalid target: '%s' is a directory.\n"
                     "  - Tool: edit_file\n"
                     "  - Allowed project root: '%s'\n"
                     "  - Reason: `edit_file' can only modify individual files, not directories.\n"
                     "  - Guidance: Specify an individual file path inside '%s' to edit.")
             path (kargu-permission-project-root) (kargu-permission-project-root)))
    (let* ((original (or (kargu-diff--file-text path) ""))
           (matches (kargu-diff--count-literal original old-string)))
      (unless (= matches 1)
        (error "old_string not found or not unique (matches: %d). Re-read the file with read_file and provide a unique context."
               matches))
      (kargu-diff-apply-proposal
       path
       (kargu-diff--replace-first original old-string new-string)
       callback))))

(defun kargu-diff--notify (callback outcome path)
  "Deliver OUTCOME to CALLBACK for PATH, never signaling."
  (when callback
    (condition-case-unless-debug err
        (funcall callback outcome)
      (error
       (kargu-log 'error "diff callback for %s failed: %s"
                  path (error-message-string err))))))

(defun kargu-diff--describe (outcome)
  "Return a model-facing description string for an OUTCOME plist."
  (let ((status (plist-get outcome :status))
        (path (plist-get outcome :file))
        (saved (plist-get outcome :saved)))
    (cond
     ((eq status :applied-full)
      (if (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'auto))
          (format "APPLIED: the change to %s has been applied%s. Verify it with lsp_diagnostics."
                  path (if saved " and the file is saved" ""))
        (format "APPLIED: the human accepted the proposal for %s%s. Verify it with lsp_diagnostics."
                path (if saved " and the file is saved" ""))))
     ((eq status :applied-partial)
      (format "APPLIED PARTIALLY: the human accepted some hunks of %s%s and kept the original for the others. Do not assume your full proposal is on disk: read the file again (read_file) and check lsp_diagnostics."
              path (if saved " and it is saved" "")))
     ((eq status :rejected)
      (format "REJECTED: the human kept the original %s; nothing was written. Do not repeat the same edit; ask what to change or propose an alternative."
              path))
     ((eq status :interrupted)
      (format "REJECTED: the human interrupted the review of %s (C-g); the original file is restored and no later edit_file is blocked by this session. Propose a new edit if you still need a change."
              path))
     ((eq status :unchanged)
      (format "NO-OP: your proposal for %s is identical to its current content." path))
     ((eq status :staged)
      (format "STAGED: the proposal for %s is open in an ediff review; the file stays untouched until the human finishes it. Do not treat it as applied."
              path))
     (t (format "Review of %s finished with status %s." path status)))))

;;;; Shadow buffers -------------------------------------------------------

(defun kargu-diff--shadow-name (path)
  "Return the shadow buffer name for PATH."
  (format "*kargu-shadow:%s*" (file-name-nondirectory path)))

(defun kargu-diff--make-shadow (path content)
  "Create a fresh shadow buffer holding CONTENT for PATH.
A stale shadow of the same name is killed first (shadows are
disposable).  The buffer is never file-backed, has undo disabled
and starts unmodified, so killing it later can never prompt."
  (let* ((name (kargu-diff--shadow-name path))
         (stale (get-buffer name)))
    (when stale
      (condition-case-unless-debug _err
          (progn
            (with-current-buffer stale (set-buffer-modified-p nil))
            (kill-buffer stale))
        (error (setq name (generate-new-buffer-name name)))))
    (let ((buffer (get-buffer-create name)))
      (with-current-buffer buffer
        (fundamental-mode)
        (buffer-disable-undo buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert content))
        (set-buffer-modified-p nil))
      buffer)))

;;;; Core: staging and the ediff review -----------------------------------

(defun kargu-diff-apply-proposal (file-path new-content &optional callback)
  "Propose NEW-CONTENT as the full new content of FILE-PATH.
The file is never overwritten blindly:  the proposal is staged in
a shadow buffer and reviewed in ediff with buffer A = the file
buffer (the outcome) and buffer B = the shadow.  ediff's native
keys decide hunks:  `a' keeps the original hunk, `b' adopts the
proposed hunk, unvisited hunks stay original.  A rollback
snapshot of the pre-edit content is recorded up front; quitting
ediff finalizes the review (save, change signal, notification).

CALLBACK, when non-nil, is called exactly once with the final
outcome plist (for :staged reviews this happens when the human
quits ediff).  Return value: an outcome plist with :status
:applied-full, :applied-partial, :rejected, :interrupted,
:unchanged or :staged (review pending - async mode, or a postponed
blocking review), plus :file, :saved and a model-facing :message."
  (unless (stringp new-content)
    (error "new-content must be a string"))
  (let* ((path (kargu-diff--resolve file-path))
         (exists (file-exists-p path))
         (buf-a (kargu-diff--open-proposal-buffer path))
         (original (with-current-buffer buf-a (buffer-string)))
         (prior (and (boundp 'kargu-diff--sessions)
                     (gethash path kargu-diff--sessions))))
    (when (and prior (fboundp 'kargu-diff--session-live-p) (kargu-diff--session-live-p prior))
      (error "A review is already pending for %s; finish it in ediff (q) first" path))
    (when prior
      (when (fboundp 'kargu-diff--reap-stale)
        (kargu-diff--reap-stale path)))
    (if (string= original new-content)
        (let ((outcome (list :status :unchanged :file path :saved nil)))
          (plist-put outcome :message (kargu-diff--describe outcome))
          (kargu-diff--notify callback outcome path)
          outcome)
      (if (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'auto))
          (kargu-diff--apply-auto path buf-a original new-content exists callback)
        (if (fboundp 'kargu-diff--apply-interactive)
            (kargu-diff--apply-interactive path buf-a original new-content exists callback)
          (error "kargu-diff--apply-interactive is unavailable"))))))

(defun kargu-diff--open-proposal-buffer (path)
  "Open or find buffer visiting PATH and verify it is writable."
  (let ((buf (or (find-buffer-visiting path)
                 (let ((enable-local-variables :safe)
                       (enable-dir-local-variables nil)
                       (enable-local-eval nil))
                   (find-file-noselect path)))))
    (when (with-current-buffer buf buffer-read-only)
      (error "Buffer %s is read-only; turn off read-only-mode before proposing edits"
             (buffer-name buf)))
    buf))

(defun kargu-diff--apply-auto (path buf-a original new-content exists callback)
  "Apply NEW-CONTENT to BUF-A automatically without interactive review."
  (let ((snap (list :content original
                    :created-new (not exists)
                    :at (current-time))))
    (puthash path (cons snap (gethash path kargu-diff--snapshots))
             kargu-diff--snapshots)
    (with-current-buffer buf-a
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert new-content)
        (set-buffer-modified-p t))
      (when (and (boundp 'kargu-diff-auto-save) kargu-diff-auto-save)
        (save-buffer)))
    (puthash path (list :status :applied-full
                        :saved (and (boundp 'kargu-diff-auto-save) kargu-diff-auto-save t)
                        :at (format-time-string "%H:%M:%S"))
             kargu-diff--changed)
    (when (boundp 'kargu-diff--run-modified-files)
      (cl-pushnew path kargu-diff--run-modified-files :test #'equal))
    (kargu-log 'info "diff: auto-applied %s (%d -> %d bytes)"
               path (length original) (length new-content))
    (let ((kargu-diff--current-file path))
      (with-current-buffer buf-a
        (when (boundp 'kargu-diff-after-apply-hook)
          (run-hooks 'kargu-diff-after-apply-hook))))
    (let ((outcome (list :status :applied-full
                         :file path
                         :saved (and (boundp 'kargu-diff-auto-save) kargu-diff-auto-save t))))
      (plist-put outcome :message (kargu-diff--describe outcome))
      (kargu-diff--notify callback outcome path)
      outcome)))

(provide 'kargu/tools/diff/stage)

;;; kargu/tools/diff/stage.el ends here
