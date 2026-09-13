;;; kargu/tools/diff/track.el --- Rollback snapshots and change tracking -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Snapshot stack, rollback functions, changed-file signal and run modification tracking.
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

;;;; Rollback snapshots ---------------------------------------------------

(defvar kargu-diff--snapshots (make-hash-table :test #'equal)
  "Per-file snapshot stack:  absolute path -> list of plists.
Each plist is (:content STRING :created-new BOOL :at TIME), the
newest snapshot first.  Pushed at staging time (before any
approval), popped by `kargu-diff-rollback'.")

(defvar kargu-diff--changed (make-hash-table :test #'equal)
  "Files changed by approved proposals, awaiting diagnostics.
Key: absolute path.  Value: plist (:status :saved :at).  The
agent loop reads this after tool calls and removes entries via
`kargu-diff-consume-file' once diagnostics were fetched.")

(defvar kargu-diff--run-modified-files nil
  "List of absolute file paths modified during the current agent run.")

(defun kargu-diff-snapshot-paths ()
  "Return the files that currently have rollback snapshots."
  (let ((paths nil))
    (maphash (lambda (path _stack) (push path paths))
             kargu-diff--snapshots)
    (nreverse paths)))

(defun kargu-diff-list-snapshots ()
  "Message the rollback snapshots recorded by agent edits."
  (interactive)
  (let ((paths (kargu-diff-snapshot-paths)))
    (if (null paths)
        (message "kargu: no rollback snapshots")
      (message "kargu rollback snapshots: %s"
               (string-join paths ", ")))))

(declare-function kargu-diff--resolve "kargu/tools/diff/stage" (path))

(defun kargu-diff-rollback (file-path &optional single-step)
  "Restore FILE-PATH to its initial state before agent edits in this series.
By default, restores to the earliest pre-agent snapshot (as if the prompt
was never run) and clears the file's rollback snapshot stack.
When SINGLE-STEP is non-nil (or with a prefix argument), restore only to
the content before the last edit step instead of the initial state.
A file that was originally created by an agent edit is deleted instead.
The file is also removed from the changed-file set consumed by the agent loop."
  (interactive
   (list (let ((paths (kargu-diff-snapshot-paths)))
           (if paths
               (completing-read "Roll back file to initial state: " paths nil t)
             (user-error "No rollback snapshots yet")))
         current-prefix-arg))
  (let* ((path (if (fboundp 'kargu-diff--resolve)
                   (kargu-diff--resolve file-path)
                 (expand-file-name file-path)))
         (stack (gethash path kargu-diff--snapshots)))
    (if (null stack)
        (user-error "No snapshot for %s" path)
      (let* ((snap (if single-step (car stack) (car (last stack))))
             (content (plist-get snap :content))
             (created-new (plist-get snap :created-new))
             (buffer (find-buffer-visiting path)))
        (if created-new
            (progn
              (when buffer
                (with-current-buffer buffer (set-buffer-modified-p nil))
                (condition-case-unless-debug _err
                    (kill-buffer buffer)
                  (error (message "kargu: could not kill buffer for %s" path))))
              (when (file-exists-p path)
                (delete-file path))
              (message "kargu: rolled back agent-created file %s (deleted)" path))
          (let ((current (if buffer
                             (with-current-buffer buffer (buffer-string))
                           (and (file-exists-p path)
                                (with-temp-buffer
                                  (insert-file-contents path)
                                  (buffer-string))))))
            (if (and current (string= current (or content "")))
                (message "kargu: %s is already at its initial state" path)
              (if buffer
                  (with-current-buffer buffer
                    (let ((inhibit-read-only t))
                      (erase-buffer)
                      (insert (or content "")))
                    (save-buffer))
                (write-region (or content "") nil path))
              (message "kargu: rolled back %s to initial state" path))))
        ;; pop the snapshot and clear the change signal
        (if (or (not single-step) (null (cdr stack)))
            (remhash path kargu-diff--snapshots)
          (puthash path (cdr stack) kargu-diff--snapshots))
        (remhash path kargu-diff--changed)
        (when (boundp 'kargu-diff--run-modified-files)
          (unless (gethash path kargu-diff--snapshots)
            (setq kargu-diff--run-modified-files
                  (delete path kargu-diff--run-modified-files))))
        (kargu-log 'info "diff: rollback of %s (initial=%s)" path (not single-step))
        path))))

(defun kargu-diff-rollback-all ()
  "Roll back all files modified in this series to their initial states."
  (interactive)
  (let ((paths (kargu-diff-snapshot-paths)))
    (if (null paths)
        (message "kargu: no rollback snapshots")
      (dolist (path paths)
        (kargu-diff-rollback path))
      (message "kargu: rolled back all %d modified file(s) to initial state" (length paths)))))

;;;; Changed-file signal (consumed by the loop) ---------------------------

(defun kargu-diff-changed-files ()
  "Return files changed by approved agent edits, not yet consumed."
  (hash-table-keys kargu-diff--changed))

(defun kargu-diff-consume-file (path)
  "Remove PATH from the changed-file set (the loop handled it)."
  (let ((resolved (if (fboundp 'kargu-diff--resolve)
                      (kargu-diff--resolve path)
                    (expand-file-name path))))
    (remhash resolved kargu-diff--changed)))

(defun kargu-diff-reset-run-files ()
  "Reset the list of modified files for a new agent run."
  (setq kargu-diff--run-modified-files nil))

(defun kargu-diff-run-modified-files ()
  "Return files modified during the current agent run."
  kargu-diff--run-modified-files)

;;;; Diff stats -----------------------------------------------------------

(defun kargu-diff-stat-added (stat)
  "Return added lines from diff STAT."
  (or (car-safe stat) 0))

(defun kargu-diff-stat-deleted (stat)
  "Return deleted lines from diff STAT."
  (or (cdr-safe stat) 0))

(defun kargu-diff-stat-total (stat)
  "Return total modified lines from diff STAT."
  (+ (kargu-diff-stat-added stat) (kargu-diff-stat-deleted stat)))

(defun kargu-diff-file-stats (file-path)
  "Return (ADDED . DELETED) line counts for FILE-PATH.
Compares FILE-PATH against its pre-agent snapshot.  If no snapshot
exists or diff fails, return (0 . 0)."
  (cl-block kargu-diff-file-stats
    (let ((path (ignore-errors
                  (if (fboundp 'kargu-diff--resolve)
                      (kargu-diff--resolve file-path)
                    (expand-file-name file-path)))))
      ;; Guard Clause 1: Invalid or unresolvable path
      (unless path
        (cl-return-from kargu-diff-file-stats (cons 0 0)))
      (let* ((stack (gethash path kargu-diff--snapshots))
             (base-snap (and stack (car (last stack))))
             (orig-content (and base-snap (plist-get base-snap :content)))
             (created-new (and base-snap (plist-get base-snap :created-new)))
             (curr-content (and (file-readable-p path)
                                (with-temp-buffer
                                  (insert-file-contents path)
                                  (buffer-string)))))
        ;; Guard Clause 2: Newly created file
        (when created-new
          (let ((lines (if curr-content
                           (with-temp-buffer
                             (insert curr-content)
                             (count-lines (point-min) (point-max)))
                         0)))
            (cl-return-from kargu-diff-file-stats (cons lines 0))))
        ;; Guard Clause 3: Content missing or unchanged
        (unless (and orig-content curr-content)
          (cl-return-from kargu-diff-file-stats (cons 0 0)))
        ;; Compute diff using system diff
        (let ((file-orig (make-temp-file "kargu-stat-orig"))
              (file-curr (make-temp-file "kargu-stat-curr"))
              (added 0)
              (deleted 0))
          (unwind-protect
              (condition-case nil
                  (progn
                    (with-temp-file file-orig (insert orig-content))
                    (with-temp-file file-curr (insert curr-content))
                    (with-temp-buffer
                      (call-process "diff" nil t nil "-u" file-orig file-curr)
                      (goto-char (point-min))
                      (while (not (eobp))
                        (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
                          (cond
                           ((string-prefix-p "+++" line) nil)
                           ((string-prefix-p "---" line) nil)
                           ((string-prefix-p "+" line) (setq added (1+ added)))
                           ((string-prefix-p "-" line) (setq deleted (1+ deleted)))))
                        (forward-line 1)))
                    (cons added deleted))
                (error (cons 0 0)))
            (when (file-exists-p file-orig) (delete-file file-orig))
            (when (file-exists-p file-curr) (delete-file file-curr))))))))

(provide 'kargu/tools/diff/track)

;;; kargu/tools/diff/track.el ends here
