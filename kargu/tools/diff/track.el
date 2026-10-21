;;; track.el --- Rollback snapshots and change tracking -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Snapshot stack, rollback functions, changed-file signal and run modification tracking.
;; Separated from `kargu/tools/diff' for single responsibility.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/files)

(declare-function kargu-lsp-diagnostics-snapshot "kargu/tools/lsp/diagnostics" (file-path))
(declare-function kargu-lsp-current-diagnostics-p "kargu/tools/lsp/freshness" (buffer))

;;;; Rollback snapshots ---------------------------------------------------

(defvar kargu-diff--snapshots (make-hash-table :test #'equal)
  "Per-file snapshot stack:  absolute path -> list of plists.
Each plist is (:content STRING :created-new BOOL :at TIME :coding CODING
:disk-revision REV :post-content STRING :post-tick INT :post-disk-revision REV
:baseline-diagnostics LIST :baseline-available BOOL), the newest snapshot first.
Pushed at commit time (after review/pre-commit validation), popped by
`kargu-diff-rollback'.")

(defvar kargu-diff--changed (make-hash-table :test #'equal)
  "Files changed by approved proposals, awaiting diagnostics.
Key: absolute path.  Value: plist (:status :saved :at :baseline-diagnostics
:baseline-available).  A verification batch captures record identities and
releases them on completion or cancellation, preserving newer edits.
Consuming a signal is not proof that diagnostics are available or clean.")

(defvar kargu-diff--run-modified-files nil
  "List of absolute file paths modified during the current agent run.")

(defun kargu-diff--disk-revision (path)
  "Return `kargu-file-revision' for PATH on disk, or nil when absent."
  (when (file-exists-p path)
    (ignore-errors (kargu-file--file-revision path))))

(defun kargu-diff--buffer-full-text (buffer)
  "Return complete widened text of BUFFER without moving point or narrowing."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (buffer-string)))))

(defun kargu-diff--capture-baseline-diagnostics (path)
  "Capture (:available BOOL :diagnostics LIST) for PATH before editing."
  (let* ((buf (find-buffer-visiting path))
         (available (and (buffer-live-p buf)
                         (fboundp 'kargu-lsp-current-diagnostics-p)
                         (kargu-lsp-current-diagnostics-p buf)
                         (fboundp 'kargu-lsp-diagnostics-snapshot)))
         (diags (when available
                  (condition-case nil
                      (copy-tree (kargu-lsp-diagnostics-snapshot path))
                    (error (setq available nil) nil)))))
    (list :available (and available t) :diagnostics diags)))

(defun kargu-diff--replace-buffer-preserving-view (buffer new-content)
  "Replace widened contents of BUFFER with NEW-CONTENT, keeping view and point."
  (with-current-buffer buffer
    (let* ((was-narrowed (buffer-narrowed-p))
           (old-min (point-min))
           (old-max (point-max))
           (old-pt (point))
           (rel-pt (max 0 (- old-pt old-min)))
           (inhibit-read-only t))
      (widen)
      (erase-buffer)
      (insert (or new-content ""))
      (when was-narrowed
        (let* ((total (point-max))
               (new-min (min total (max 1 old-min)))
               (new-max (min total (max new-min old-max))))
          (narrow-to-region new-min new-max)))
      (goto-char (min (point-max) (+ (point-min) rel-pt))))))

(defun kargu-diff--snapshot-unmodified-since-commit-p (path snap)
  "Return non-nil when PATH has not been modified by user or disk since SNAP."
  (if (plist-get snap :deleted)
      (and (not (file-exists-p path))
           (not (find-buffer-visiting path)))
    (let ((buf (find-buffer-visiting path))
          (post-content (plist-get snap :post-content))
          (post-tick (plist-get snap :post-tick))
          (post-disk (plist-get snap :post-disk-revision)))
      (and (or (not (buffer-live-p buf))
               (and (or (null post-tick)
                        (eql post-tick (buffer-chars-modified-tick buf)))
                    (or (null post-content)
                        (string= (kargu-diff--buffer-full-text buf) post-content))))
           (if post-disk
               (equal post-disk (kargu-diff--disk-revision path))
             (not (file-exists-p path)))))))

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

(defun kargu-diff--rollback-created-file (path buffer &optional snap)
  "Roll back an agent-created file at PATH, killing BUFFER and deleting the file.
Refuse when SNAP indicates user or external edits occurred since commit."
  (when (and snap (plist-member snap :post-content)
             (not (kargu-diff--snapshot-unmodified-since-commit-p path snap)))
    (error "Rollback conflict for %s: file or buffer was modified after the agent edit" path))
  (when buffer
    (with-current-buffer buffer (set-buffer-modified-p nil))
    (condition-case-unless-debug _err
        (kill-buffer buffer)
      (error (message "kargu: could not kill buffer for %s" path))))
  (when (file-exists-p path)
    (delete-file path))
  (message "kargu: rolled back agent-created file %s (deleted)" path))

(defun kargu-diff--rollback-existing-file (path buffer content &optional snap latest)
  "Restore an existing file at PATH with BUFFER to CONTENT.
Refuse when LATEST or SNAP indicates edits occurred since commit."
  (let ((guard (or latest snap)))
    (when (and guard (or (plist-member guard :post-content) (plist-get guard :deleted))
               (not (kargu-diff--snapshot-unmodified-since-commit-p path guard)))
      (error "Rollback conflict for %s: file or buffer was modified after the agent edit" path)))
  (let ((current (if buffer
                     (kargu-diff--buffer-full-text buffer)
                   (and (file-exists-p path)
                        (with-temp-buffer
                          (insert-file-contents path)
                          (buffer-string))))))
    (if (and current (string= current (or content "")))
        (message "kargu: %s is already at its initial state" path)
      (if buffer
          (with-current-buffer buffer
            (kargu-diff--replace-buffer-preserving-view buffer (or content ""))
            (when-let* ((coding (and snap (plist-get snap :coding))))
              (setq buffer-file-coding-system coding))
            (let ((before-save-hook nil) (after-save-hook nil)
                  (write-contents-functions nil) (write-file-functions nil))
              (save-buffer)))
        (let ((coding-system-for-write (or (and snap (plist-get snap :coding))
                                           coding-system-for-write)))
          (write-region (or content "") nil path nil 'silent)))
      (message "kargu: rolled back %s to initial state" path))))

(defun kargu-diff--pop-snapshot-and-clear (path stack single-step)
  "Pop snapshot STACK for PATH and clear change tracking."
  (if (or (not single-step) (null (cdr stack)))
      (remhash path kargu-diff--snapshots)
    (let ((remaining (cdr stack))
          (buffer (find-buffer-visiting path)))
      (plist-put (car remaining) :post-tick
                 (and buffer (buffer-chars-modified-tick buffer)))
      (plist-put (car remaining) :post-disk-revision (kargu-diff--disk-revision path))
      (puthash path remaining kargu-diff--snapshots)))
  (remhash path kargu-diff--changed)
  (when (boundp 'kargu-diff--run-modified-files)
    (unless (gethash path kargu-diff--snapshots)
      (setq kargu-diff--run-modified-files
            (delete path kargu-diff--run-modified-files))))
  (kargu-log 'info "diff: rollback of %s (initial=%s)" path (not single-step)))

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
  (let* ((path (kargu-permission-resolve file-path "file"))
         (stack (gethash path kargu-diff--snapshots)))
    (if (null stack)
        (user-error "No snapshot for %s" path)
      (let* ((latest (car stack))
             (snap (if single-step latest (car (last stack))))
             (content (plist-get snap :content))
             (created-new (plist-get snap :created-new))
             (buffer (find-buffer-visiting path)))
        (when (and latest (or (plist-member latest :post-content) (plist-get latest :deleted))
                   (not (kargu-diff--snapshot-unmodified-since-commit-p path latest)))
          (error "Rollback conflict for %s: file or buffer was modified after the agent edit" path))
        (if created-new
            (kargu-diff--rollback-created-file path buffer latest)
          (kargu-diff--rollback-existing-file path buffer content snap latest))
        (when (and single-step (cdr stack))
          (let ((prev (cadr stack)))
            (plist-put prev :post-content (if (buffer-live-p buffer)
                                              (kargu-diff--buffer-full-text buffer)
                                            content))
            (plist-put prev :post-tick (and (buffer-live-p buffer)
                                            (buffer-chars-modified-tick buffer)))
            (plist-put prev :post-disk-revision (kargu-diff--disk-revision path))))
        (kargu-diff--pop-snapshot-and-clear path stack single-step)
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

(cl-defstruct (kargu-diff-change (:constructor kargu-diff--make-change))
  "Opaque identity of one pending change at its captured absolute PATH."
  path identity)

(defun kargu-diff-pending-change (path)
  "Capture PATH's pending change identity, or nil when no change is recorded."
  (let* ((resolved (kargu-permission-resolve path "file"))
         (identity (gethash resolved kargu-diff--changed)))
    (when identity (kargu-diff--make-change :path resolved :identity identity))))

(defun kargu-diff-change-baseline (change)
  "Return (:available BOOL :diagnostics LIST) recorded on captured CHANGE."
  (when (kargu-diff-change-p change)
    (let ((id (kargu-diff-change-identity change)))
      (when (listp id)
        (or (plist-get id :baseline)
            (list :available (and (plist-get id :baseline-available) t)
                  :diagnostics (plist-get id :baseline-diagnostics)))))))

(defun kargu-diff-consume-change (change)
  "Consume captured CHANGE only if no newer edit replaced its record.
The captured absolute path is independent of later project selection."
  (when (and change
             (eq (kargu-diff-change-identity change)
                 (gethash (kargu-diff-change-path change) kargu-diff--changed)))
    (remhash (kargu-diff-change-path change) kargu-diff--changed)
    t))

(defun kargu-diff-consume-file (path)
  "Remove PATH from the changed-file set (the loop handled it)."
  (let ((resolved (kargu-permission-resolve path "file")))
    (remhash resolved kargu-diff--changed)))

(defun kargu-diff-reset-run-files ()
  "Reset the list of modified files for a new agent run."
  (setq kargu-diff--run-modified-files nil))

(defun kargu-diff-run-modified-files ()
  "Return files modified during the current agent run."
  kargu-diff--run-modified-files)

;;;; Diff stats -----------------------------------------------------------

(defun kargu-diff--trim-common-lines (old new)
  "Drop the common leading and trailing lines of the line lists OLD and NEW.
Return (OLD-MIDDLE . NEW-MIDDLE)."
  (while (and old new (equal (car old) (car new)))
    (setq old (cdr old) new (cdr new)))
  (let ((rold (reverse old))
        (rnew (reverse new)))
    (while (and rold rnew (equal (car rold) (car rnew)))
      (setq rold (cdr rold) rnew (cdr rnew)))
    (cons (nreverse rold) (nreverse rnew))))

(defun kargu-diff--count-unmatched (lines other)
  "How many of LINES have no counterpart in OTHER (each counterpart used once)."
  (let ((pool (make-hash-table :test #'equal))
        (unmatched 0))
    (dolist (line other)
      (puthash line (1+ (gethash line pool 0)) pool))
    (dolist (line lines)
      (let ((n (gethash line pool 0)))
        (if (> n 0)
            (puthash line (1- n) pool)
          (setq unmatched (1+ unmatched)))))
    unmatched))

(defun kargu-diff--count-unified-changes (orig-content curr-content)
  "Compute (ADDED . DELETED) line counts between ORIG-CONTENT and CURR-CONTENT.
Common leading and trailing lines are skipped, then the lines left on each
side are matched as multisets.  It runs in-process in linear time, so the
chat never waits for an external `diff'."
  (let* ((middle (kargu-diff--trim-common-lines
                  (split-string orig-content "\n")
                  (split-string curr-content "\n"))))
    (cons (kargu-diff--count-unmatched (cdr middle) (car middle))
          (kargu-diff--count-unmatched (car middle) (cdr middle)))))

(defun kargu-diff-file-stats (file-path)
  "Return (ADDED . DELETED) line counts for FILE-PATH.
Compares FILE-PATH against its pre-agent snapshot.  If no snapshot
exists or diff fails, return (0 . 0)."
  (let ((path (ignore-errors
                (kargu-permission-resolve file-path "file"))))
    (if (null path)
        (cons 0 0)
      (let* ((stack (gethash path kargu-diff--snapshots))
             (base-snap (and stack (car (last stack))))
             (orig-content (and base-snap (plist-get base-snap :content)))
             (created-new (and base-snap (plist-get base-snap :created-new)))
             (curr-content (and (file-readable-p path)
                                (with-temp-buffer
                                  (insert-file-contents path)
                                  (buffer-string)))))
        (cond
         (created-new
          (let ((lines (if curr-content
                           (with-temp-buffer
                             (insert curr-content)
                             (count-lines (point-min) (point-max)))
                         0)))
            (cons lines 0)))
         ((and orig-content curr-content)
          (kargu-diff--count-unified-changes orig-content curr-content))
         (t
          (cons 0 0)))))))

(provide 'kargu/tools/diff/track)

;;; track.el ends here
