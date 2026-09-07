;;; kargu/tools/diff.el --- Shadow buffers, ediff, rollback -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shadow buffers, ediff review, and rollback.  Ediff path is unchanged.
;; Requires: `kargu/core', `kargu/api', `kargu/tools/lsp'.
;; Public: `kargu-diff-apply-replace', `kargu-diff-apply-proposal',
;; `kargu-diff-rollback', `kargu-diff-changed-files'.
;;
;; The edit-application layer:  every change the model proposes is
;; staged in a disposable SHADOW BUFFER and reviewed by the human in
;; ediff, hunk by hunk.  Nothing reaches the file until the human
;; approves it, and every accepted edit stays reversible.
;;
;; Review design (the buffer roles are the whole trick):
;;   buffer A = the real file buffer, starting at its current
;;              content - this is the OUTCOME buffer;
;;   buffer B = *kargu-shadow:<file>*, holding the proposal.
;; With ediff's native keys this gives exactly the specified
;; behavior:
;;   a   copies the hunk from A to B  ->  keep the original (the
;;                                       file keeps its text);
;;   b   copies the hunk from B to A  ->  adopt the AI version for
;;                                       this hunk; an ordinary
;;                                       edit in the file buffer,
;;                                       so the undo chain stays
;;                                       intact;
;;   hunks the human never visits keep the original text.
;; Quitting ediff (q) finalizes the review:  when A differs from the
;; pre-review content, the buffer is saved (see
;; `kargu-diff-auto-save'), the file is reported to the agent
;; loop (changed-file set + `kargu-diff-after-apply-hook'),
;; and a rollback snapshot of the pre-edit content has already been
;; recorded.
;;
;; Rollback has two layers:  the file buffer's own undo history
;; (staging never touches it, 'b' hunks are regular buffer edits),
;; and a per-file content-snapshot stack consulted by
;; `kargu-diff-rollback', which also deletes files the agent
;; created and reverts even after the buffer was killed.
;;
;; Loop integration (consumed by `kargu/loop'):
;;   * `kargu-diff-apply-proposal' returns an outcome plist
;;     (:status :applied-full | :applied-partial | :rejected |
;;     :interrupted | :unchanged | :staged) whose :message is ready
;;     for the model;
;;   * in the default `blocking' review mode the `edit_file' tool
;;     blocks on the human review (a recursive edit) and reports the
;;     REAL final state, so the loop runs its diagnostics
;;     verification after approval, never before;
;;   * `kargu-diff-changed-files' and
;;     `kargu-diff-consume-file' track files awaiting
;;     diagnostics feedback.
;;
;; Tools registered here:  `read_file' (line-numbered dump),
;; `edit_file' (surgical old_string -> new_string, unique match,
;; then the same human-reviewed shadow/ediff path), and
;; `write_file' (create a file that does not exist yet).  Mutating
;; tools are refused outside agent mode (the system prompts already
;; forbid edits there; this is the enforcement net).
;;
;; Known trade-off:  when the file buffer carries the user's own
;; unsaved modifications at staging time, they become part of the
;; diff baseline, and saving after an approved review persists them
;; together with the accepted hunks.  The human sees every one of
;; them inside ediff, so nothing is ever applied blind.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ediff)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
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
(require 'kargu/api)
(require 'kargu/permission)
(require 'kargu/tools/lsp)         ; only for kargu--resolve-path

(defvar ediff-buffer-A)                  ; buffer-local in ediff control buffers
(declare-function ediff-really-quit "ediff-util")

;;;; Customization --------------------------------------------------------

(defgroup kargu-diff nil
  "Shadow-buffer editing, ediff approval and rollback."
  :group 'kargu
  :prefix "kargu-diff-")

(defcustom kargu-diff-review-mode 'auto
  "How proposed file modifications are applied during agent runs.
`auto'      apply and save proposed edits immediately during the
            agent run without interactive ediff interruptions.
            Rollback snapshots are kept so the user can review
            changes via `kargu-diff-review' or roll back via
            `kargu-diff-rollback' after the run finishes.
`blocking'  the tool call blocks (a recursive edit) and pops up
            an ediff session for human hunk-by-hunk approval
            before anything is saved to disk.
`async'     the tool returns immediately with a STAGED result;
            the final outcome is delivered when ediff is quitted."
  :type '(choice (const :tag "Auto-apply and save (review afterwards)" auto)
                 (const :tag "Block on ediff review before each edit" blocking)
                 (const :tag "Return immediately, notify later" async))
  :group 'kargu-diff)

(defcustom kargu-diff-auto-save t
  "Save the file buffer automatically after an approved review.
The human just approved each hunk explicitly, so saving is the
expected outcome.  When nil the buffer stays modified and the
user saves (or reverts) it manually."
  :type 'boolean
  :group 'kargu-diff)

(defcustom kargu-diff-keep-shadow nil
  "Keep shadow buffers (*kargu-shadow:...*) after review.
Useful to inspect exactly what was proposed; shadows are
otherwise killed shortly after the review finishes."
  :type 'boolean
  :group 'kargu-diff)

(defcustom kargu-diff-read-max-chars 60000
  "Character cap for the `read_file' tool result.
The text fed back to the model is additionally capped by
`kargu-tool-output-limit'."
  :type 'natnum
  :group 'kargu-diff)

(defcustom kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain
  "Function called by ediff to set up windows during kargu reviews.
Defaults to `ediff-setup-windows-plain' so that ediff runs within the
current Emacs frame instead of spawning external OS frames (especially
important in tiling window managers like i3wm)."
  :type 'function
  :group 'kargu-diff)

(defcustom kargu-diff-ediff-split-window-function #'split-window-horizontally
  "Function used by ediff to split the window between Buffer A and Buffer B.
Defaults to `split-window-horizontally' so that Buffer A (old code) is on
the left and Buffer B (new code) is on the right."
  :type 'function
  :group 'kargu-diff)

;; Default ediff to single-frame side-by-side mode in Emacs
(setq ediff-window-setup-function #'ediff-setup-windows-plain)
(setq ediff-split-window-function #'split-window-horizontally)

(defcustom kargu-diff-after-apply-hook nil
  "Hook run after an approved proposal is saved to its file.
Runs with the file's buffer current;
`kargu-diff--current-file' holds the absolute path.  The
agent loop uses this (or the changed-file set) to trigger
diagnostics verification."
  :type 'hook
  :group 'kargu-diff)

(defvar kargu-diff--current-file nil
  "Absolute path of the file reported by `kargu-diff-after-apply-hook'.
Dynamically bound while the hook runs.")

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

(defun kargu-diff--to-int (value)
  "Coerce VALUE (integer, float or numeric string) to an integer.
Return nil when VALUE is nil or not numeric."
  (cond
   ((integerp value) value)
   ((numberp value) (round value))
   ((stringp value)
    (ignore-errors (cl-parse-integer value :junk-allowed t)))
   (t nil)))

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
      (error "No such file: %s; use write_file to create it" path))
    (when (file-directory-p path)
      (error "%s is a directory; edit_file only changes files" path))
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
      (if (eq kargu-diff-review-mode 'auto)
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
  (let* ((path (kargu-diff--resolve file-path))
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
  (remhash (kargu-diff--resolve path) kargu-diff--changed))

(defvar kargu-diff--run-modified-files nil
  "List of absolute file paths modified during the current agent run.")

(defun kargu-diff-reset-run-files ()
  "Reset the list of modified files for a new agent run."
  (setq kargu-diff--run-modified-files nil))

(defun kargu-diff-run-modified-files ()
  "Return files modified during the current agent run."
  kargu-diff--run-modified-files)

(defun kargu-diff-review (&optional file-path)
  "Review changes made to FILE-PATH in ediff against the pre-agent snapshot.
Buffer A (left) displays the original pre-agent snapshot, and Buffer B
(right) displays the current file buffer.  Ediff's native `a' key can
selectively revert individual hunks back to the original version."
  (interactive
   (list (let ((paths (or (and (boundp 'kargu-diff--run-modified-files)
                               kargu-diff--run-modified-files)
                          (kargu-diff-snapshot-paths))))
           (if paths
               (completing-read "Review file diff in ediff: " paths nil t
                                nil nil (car paths))
             (user-error "No modified files or rollback snapshots available")))))
  (let* ((path (kargu-diff--resolve (or file-path
                                        (car (or (and (boundp 'kargu-diff--run-modified-files)
                                                      kargu-diff--run-modified-files)
                                                 (kargu-diff-snapshot-paths))))))
         (stack (gethash path kargu-diff--snapshots)))
    (unless stack
      (user-error "No rollback snapshot recorded for %s" path))
    (let* ((orig-snap (car (last stack)))
           (original (plist-get orig-snap :content)))
      (kargu-diff--rollback-review path original))))

(defun kargu-diff--restore-wconfig (wconfig)
  "Restore WCONFIG and ensure chat buffer windows stay at latest content."
  (when (window-configuration-p wconfig)
    (set-window-configuration wconfig)
    (dolist (win (window-list))
      (let ((buf (window-buffer win)))
        (when (and (buffer-live-p buf)
                   (with-current-buffer buf (derived-mode-p 'kargu-chat-mode)))
          (with-current-buffer buf
            (set-window-point win (point-max))))))))

(defun kargu-diff--rollback-review (path original)
  "Open ediff comparing pre-edit ORIGINAL with the current state of PATH."
  (let* ((buf-file (or (find-buffer-visiting path)
                       (find-file-noselect path)))
         (buf-orig (get-buffer-create (format "*kargu-orig:%s*" (file-name-nondirectory path))))
         (wconfig (current-window-configuration)))
    (with-current-buffer buf-orig
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or original ""))
        (set-buffer-modified-p nil))
      (setq buffer-read-only t))
    (let* ((ediff-window-setup-function (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain))
           (ediff-split-window-function (or kargu-diff-ediff-split-window-function #'split-window-horizontally))
           (ctl (ediff-buffers buf-orig buf-file)))
      (when (bufferp ctl)
        (with-current-buffer ctl
          (add-hook 'ediff-after-quit-hook-internal
                    (lambda ()
                      (kargu-diff--restore-wconfig wconfig)
                      (run-at-time 0 nil
                                   (lambda (buf)
                                     (when (buffer-live-p buf)
                                       (kill-buffer buf)))
                                   buf-orig))
                    nil t)
          (add-hook 'kill-buffer-hook
                    (lambda ()
                      (kargu-diff--restore-wconfig wconfig)
                      (run-at-time 0 nil
                                   (lambda (buf)
                                     (when (buffer-live-p buf)
                                       (kill-buffer buf)))
                                   buf-orig))
                    nil t)))
      ctl)))

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
    (let ((path (ignore-errors (kargu-diff--resolve file-path))))
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

;;;; Review sessions ------------------------------------------------------

(defvar kargu-diff--sessions (make-hash-table :test #'equal)
  "Pending review sessions:  absolute path -> session plist.
Keys of a session plist:  :path, :buffer-a, :shadow-buffer,
:original, :proposal, :created-new, :callback, :blocking,
:ediff-control, :outcome.")

(defun kargu-diff--session-live-p (session)
  "Return non-nil when SESSION's ediff review may still be running.
The ediff control buffer decides; a missing control reference
falls back to the shadow buffer's liveness."
  (let ((control (plist-get session :ediff-control)))
    (if control
        (buffer-live-p control)
      (buffer-live-p (plist-get session :shadow-buffer)))))

(defun kargu-diff--maybe-drop-hook ()
  "Remove our ediff quit hook when no review sessions are pending."
  (when (= 0 (hash-table-count kargu-diff--sessions))
    (remove-hook 'ediff-quit-hook #'kargu-diff--ediff-quit)))

(defun kargu-diff--reap-stale (path)
  "Clean up an abandoned (never finalized) review for PATH.
Abandonment means the ediff control buffer died without running
our quit hook, e.g. it was killed directly."
  (let ((session (gethash path kargu-diff--sessions)))
    (when session
      (kargu-diff--abort-session session t)
      (kargu-log 'warn "diff: dropped abandoned review for %s" path))))

(defun kargu-diff--abort-session (session &optional silent)
  "Cancel the active review for SESSION."
  (let ((path (plist-get session :path))
        (buf-a (plist-get session :buffer-a))
        (shadow (plist-get session :shadow-buffer))
        (original (plist-get session :original))
        (control (plist-get session :ediff-control))
        (callback (plist-get session :callback)))
    (when (and path (eq session (gethash path kargu-diff--sessions)))
      (remhash path kargu-diff--sessions))
    (when (buffer-live-p buf-a)
      (with-current-buffer buf-a
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert original)
          (set-buffer-modified-p nil))))
    (when (buffer-live-p control)
      (with-current-buffer control
        (remove-hook 'ediff-quit-hook #'kargu-diff--ediff-quit t)
        (when (boundp 'ediff-quit-hook)
          (setq ediff-quit-hook
                (remq #'kargu-diff--ediff-quit ediff-quit-hook)))
        (condition-case-unless-debug _err
            (with-current-buffer control
              (if (fboundp 'ediff-really-quit)
                  (ediff-really-quit nil)
                (kill-buffer control)))
          (error
           (when (buffer-live-p control)
             (kill-buffer control))))))
    (when (buffer-live-p shadow)
      (with-current-buffer shadow (set-buffer-modified-p nil))
      (kill-buffer shadow))
    (when-let* ((wconfig (plist-get session :window-config)))
      (kargu-diff--restore-wconfig wconfig))
    (let ((outcome (list :status :interrupted :file path :saved nil)))
      (plist-put outcome :message (kargu-diff--describe outcome))
      (plist-put session :outcome outcome)
      (unless silent
        (kargu-diff--notify callback outcome path)
        (kargu-log 'warn "diff: review interrupted for %s" path))
      outcome)))

(defun kargu-diff-pending-reviews ()
  "Message the agent reviews that are still open in ediff."
  (interactive)
  (let ((paths nil))
    (maphash (lambda (path session)
               (when (kargu-diff--session-live-p session)
                 (push path paths)))
             kargu-diff--sessions)
    (if (null paths)
        (message "kargu: no pending reviews")
      (message "kargu pending reviews: %s"
               (string-join (nreverse paths) ", ")))))

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
         (buf-a (or (find-buffer-visiting path)
                    ;; Programmatic open: apply only safe local
                    ;; variables so no prompt can interrupt the flow.
                    (let ((enable-local-variables :safe)
                          (enable-dir-local-variables nil)
                          (enable-local-eval nil))
                      (find-file-noselect path))))
         (original (with-current-buffer buf-a (buffer-string)))
         (prior (gethash path kargu-diff--sessions)))
    (when (and prior (kargu-diff--session-live-p prior))
      (error "A review is already pending for %s; finish it in ediff (q) first" path))
    (when prior
      (kargu-diff--reap-stale path))
    (when (with-current-buffer buf-a buffer-read-only)
      (error "Buffer %s is read-only; turn off read-only-mode before proposing edits"
             (buffer-name buf-a)))
    (if (string= original new-content)
        (let ((outcome (list :status :unchanged :file path :saved nil)))
          (plist-put outcome :message (kargu-diff--describe outcome))
          (kargu-diff--notify callback outcome path)
          outcome)
      (if (eq kargu-diff-review-mode 'auto)
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
              (when kargu-diff-auto-save
                (save-buffer)))
            (puthash path (list :status :applied-full
                                :saved (and kargu-diff-auto-save t)
                                :at (format-time-string "%H:%M:%S"))
                     kargu-diff--changed)
            (when (boundp 'kargu-diff--run-modified-files)
              (cl-pushnew path kargu-diff--run-modified-files :test #'equal))
            (kargu-log 'info "diff: auto-applied %s (%d -> %d bytes)"
                       path (length original) (length new-content))
            (let ((kargu-diff--current-file path))
              (with-current-buffer buf-a
                (run-hooks 'kargu-diff-after-apply-hook)))
            (let ((outcome (list :status :applied-full
                                 :file path
                                 :saved (and kargu-diff-auto-save t))))
              (plist-put outcome :message (kargu-diff--describe outcome))
              (kargu-diff--notify callback outcome path)
              outcome))
        ;; Otherwise: interactive ediff review (blocking or async)
        (let* ((wconfig (current-window-configuration))
               (shadow (kargu-diff--make-shadow path new-content))
               (snap (list :content original
                           :created-new (not exists)
                           :at (current-time)))
               (session (list :path path
                              :buffer-a buf-a
                              :shadow-buffer shadow
                              :original original
                              :proposal new-content
                              :created-new (not exists)
                              :callback callback
                              :blocking (eq kargu-diff-review-mode 'blocking)
                              :window-config wconfig
                              :outcome nil)))
          (puthash path (cons snap (gethash path kargu-diff--snapshots))
                   kargu-diff--snapshots)
          (puthash path session kargu-diff--sessions)
          (kargu-log 'info "diff: proposal staged for %s (%d -> %d bytes)"
                            path (length original) (length new-content))
          (add-hook 'ediff-quit-hook #'kargu-diff--ediff-quit)
          (when (fboundp 'kargu-notify)
            (kargu-notify 'permission))
          (let ((control (condition-case-unless-debug err
                            (let ((ediff-window-setup-function (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain))
                                  (ediff-split-window-function (or kargu-diff-ediff-split-window-function #'split-window-horizontally)))
                              (ediff-buffers buf-a shadow))
                          (error
                           (remhash path kargu-diff--sessions)
                           (when (buffer-live-p shadow) (kill-buffer shadow))
                           (kargu-diff--maybe-drop-hook)
                           (error "Could not start ediff review: %s"
                                  (error-message-string err))))))
            (plist-put session :ediff-control
                       (if (bufferp control)
                           control
                         (and (stringp control) (get-buffer control))))
            (when (bufferp control)
              (with-current-buffer control
                (add-hook 'ediff-after-quit-hook-internal
                          (lambda ()
                            (kargu-diff--restore-wconfig wconfig))
                          nil t)
                (add-hook 'kill-buffer-hook
                          (lambda ()
                            (when (gethash path kargu-diff--sessions)
                              (kargu-diff--ediff-quit))
                            (kargu-diff--restore-wconfig wconfig))
                          nil t))))
          (if (eq kargu-diff-review-mode 'blocking)
              (progn
                (condition-case-unless-debug _sig
                    (recursive-edit)
                  (quit
                   (kargu-diff--abort-session session)
                   (message "kargu: review interrupted; the file is restored")))
                (kargu-diff--restore-wconfig wconfig)
                (or (plist-get session :outcome)
                    (let ((outcome (list :status :staged :file path :saved nil)))
                      (plist-put outcome :message (kargu-diff--describe outcome))
                      outcome)))
            (let ((outcome (list :status :staged :file path :saved nil)))
              (plist-put outcome :message (kargu-diff--describe outcome))
              outcome)))))))

(defun kargu-diff--ediff-quit ()
  "Finalize the agent review whose ediff session just ended.
Installed on `ediff-quit-hook' while reviews are pending; runs in
the ediff control buffer, where `ediff-buffer-A' names the
file-side buffer.  Sessions of other ediff windows are ignored.
Removes itself from the hook when no review is pending."
  (let ((buf-a (and (boundp 'ediff-buffer-A)
                    (bufferp ediff-buffer-A)
                    (buffer-live-p ediff-buffer-A)
                    ediff-buffer-A)))
    (when buf-a
      (let ((match nil))
        (maphash (lambda (_path session)
                   (unless match
                     (when (eq (plist-get session :buffer-a) buf-a)
                       (setq match session))))
                 kargu-diff--sessions)
        (when match
          (kargu-log 'debug "diff: ediff quit, finalizing review of %s"
                           (plist-get match :path))
          (condition-case-unless-debug err
              (kargu-diff--finalize match)
            (error
             (kargu-log 'error "diff finalize failed: %s"
                              (error-message-string err))))
          ;; release the blocking tool call, if any
          (when (plist-get match :blocking)
            (run-at-time 0 nil
                         (lambda ()
                           (condition-case-unless-debug _sig
                               (exit-recursive-edit)
                             (error
                              (kargu-log 'debug
                                         "diff: no recursive edit to exit")))))))))
    (kargu-diff--maybe-drop-hook)))

(defun kargu-diff--finalize (session)
  "Finish the review of SESSION and return the outcome plist.
Saves the file buffer when hunks were accepted, records the
change signal, runs `kargu-diff-after-apply-hook', notifies
the session callback and schedules shadow cleanup."
  (let* ((path (plist-get session :path))
         (buf-a (plist-get session :buffer-a))
         (shadow (plist-get session :shadow-buffer))
         (original (plist-get session :original))
         (proposal (plist-get session :proposal))
         (created-new (plist-get session :created-new))
         (callback (plist-get session :callback))
         status saved outcome)
    (remhash path kargu-diff--sessions)
    (kargu-diff--maybe-drop-hook)
    (if (not (buffer-live-p buf-a))
        ;; the file buffer died during review: nothing was written
        (setq status :rejected)
      (with-current-buffer buf-a
        (let ((final (buffer-string)))
          (setq status
                (cond
                 ((string= final original) :rejected)
                 ((string= final proposal) :applied-full)
                 (t :applied-partial)))
          (when (and (memq status '(:applied-full :applied-partial))
                     kargu-diff-auto-save
                     (buffer-modified-p))
            (save-buffer)
            (setq saved t))
          ;; a rejected proposal for a brand-new file leaves an
          ;; empty, unmodified shell buffer behind: drop it
          (when (and created-new (eq status :rejected)
                     (not (buffer-modified-p)))
            (kill-buffer)))))
    (setq outcome (list :status status :file path :saved (and saved t)))
    (plist-put outcome :message (kargu-diff--describe outcome))
    (plist-put session :outcome outcome)
    (when (memq status '(:applied-full :applied-partial))
      (puthash path (list :status status :saved (and saved t)
                          :at (format-time-string "%H:%M:%S"))
               kargu-diff--changed)
      (when (boundp 'kargu-diff--run-modified-files)
        (cl-pushnew path kargu-diff--run-modified-files :test #'equal))
      (kargu-log 'info "diff: %s %s" status path)
      (when (buffer-live-p buf-a)
        (let ((kargu-diff--current-file path))
          (with-current-buffer buf-a
            (run-hooks 'kargu-diff-after-apply-hook)))))
    (unless (or kargu-diff-keep-shadow
                (not (buffer-live-p shadow)))
      ;; deferred so ediff can complete its own quit first
      (run-at-time 0 nil
                   (lambda (buf)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf (set-buffer-modified-p nil))
                       (kill-buffer buf)))
                   shadow))
    (unless (plist-get session :blocking)
      (when-let* ((wconfig (plist-get session :window-config)))
        (run-at-time 0 nil
                     (lambda (cfg)
                       (when (window-configuration-p cfg)
                         (set-window-configuration cfg)))
                     wconfig)))
    (kargu-diff--notify callback outcome path)
    outcome))

;;;; File reading (companion tool) ----------------------------------------

(defun kargu-diff-read-file (file-path &optional from-line to-line)
  "Return a model-oriented dump of FILE-PATH.
FROM-LINE and TO-LINE (1-based, inclusive) select a line window;
without them the whole file is served, capped at
`kargu-diff-read-max-chars'.  Each served line is prefixed with
its 1-based file line number (`12 | ...') so the model can copy
an exact `old_string' without the prefix."
  (let* ((live-buf (and (stringp file-path) (get-buffer file-path)))
         (is-buf (and live-buf (buffer-live-p live-buf)))
         (path (if is-buf file-path (kargu-diff--resolve file-path))))
    (if (and (not is-buf) (not (file-exists-p path)))
        (error "No such file: %s" path)
      (let* ((text (if is-buf
                       (with-current-buffer live-buf (buffer-string))
                     (with-temp-buffer
                       (insert-file-contents path)
                       (buffer-string))))
             (lines (split-string text "\n"))
             (total (max 1 (length lines)))
             (has-window (or from-line to-line))
             (from (max 1 (or (kargu-diff--to-int from-line) 1)))
             (to (min (or (kargu-diff--to-int to-line) total) total)))
        (when (> from total)
          (error "from_line (%d) exceeds file line count (%d)" from total))
        (when (< to from)
          (error "to_line (%d) is before from_line (%d)" to from))
        (when (cl-position 0 (substring text 0 (min 1000 (length text))))
          (error "%s looks like a binary file; read_file only serves text" path))
        (let* ((picked (cl-subseq lines (1- from) to))
               (n from)
               (numbered
                (mapcar (lambda (line)
                          (prog1 (format "%d | %s" n line)
                            (setq n (1+ n))))
                        picked))
               (body (string-join numbered "\n"))
               (truncated (and (not has-window)
                               (> (length body) kargu-diff-read-max-chars)))
               (body (if truncated
                         (concat (substring body 0 kargu-diff-read-max-chars)
                                 "\n... [truncated; use from_line/to_line to read specific sections]")
                       body)))
          (format "(file %s, lines %d-%d of %d%s)\n%s"
                  path from to total
                  (if truncated
                      (format ", capped at %d chars"
                              kargu-diff-read-max-chars)
                    "")
                  body))))))

;;;; Tool registration -----------------------------------------------------

(defun kargu-diff--mutating-disabled (name)
  "Return an error string when mutating tool NAME is blocked."
  (unless (eq kargu-active-mode 'agent)
    (format
     "ERROR: %s is disabled in %s mode; switch to agent mode (M-x kargu-set-mode) before modifying files"
     name kargu-active-mode)))

(defun kargu-diff--edit-file-tool (args)
  "Executor for the `edit_file' tool: unique replace, stage, review."
  (or (kargu-diff--mutating-disabled "edit_file")
      (let ((path (kargu--tool-file-path args))
            (old (kargu--tool-arg args "old_string" "oldString" "old_text"))
            (new (kargu--tool-arg args "new_string" "newString" "new_text"))
            (reason (kargu--tool-arg args "reason")))
        (cond
         ((not (kargu--nonempty path))
          (kargu--tool-missing-file-path args))
         ((or (null old) (not (stringp old)) (string-empty-p old))
          "ERROR: old_string is required and must be a unique exact block from the file")
         ((null new)
          "ERROR: new_string is required (use an empty string to delete the block)")
         ((not (stringp new))
          "ERROR: new_string must be a string")
         (t
          (when (and (stringp reason) (not (string-empty-p reason)))
            (message "kargu edit proposal for %s: %s" path reason)
            (kargu-log 'info "diff: edit reason: %s" reason))
          (condition-case-unless-debug err
              (kargu-diff--describe
               (kargu-diff-apply-replace path old new))
            (error (format "ERROR: %s" (error-message-string err)))))))))

(defun kargu-diff--write-file-tool (args)
  "Executor for the `write_file' tool: create or overwrite a file via ediff."
  (or (kargu-diff--mutating-disabled "write_file")
      (let ((path (kargu--tool-file-path args))
            (contents (kargu--tool-arg-string args "contents" "content"))
            (reason (kargu--tool-arg args "reason")))
        (cond
         ((not (kargu--nonempty path))
          (kargu--tool-missing-file-path args))
         ((null contents)
          "ERROR: contents is required")
         ((not (stringp contents))
          "ERROR: contents must be a string")
         (t
          (let ((abs (ignore-errors (kargu-diff--resolve path))))
            (cond
             ((and abs (file-directory-p abs))
              (format "ERROR: %s is a directory" abs))
             (t
              (when (and (stringp reason) (not (string-empty-p reason)))
                (message "kargu write proposal for %s: %s" path reason)
                (kargu-log 'info "diff: write reason: %s" reason))
              (condition-case-unless-debug err
          (kargu-diff--describe
                   (kargu-diff-apply-proposal path contents))
                (error (format "ERROR: %s"
                               (error-message-string err))))))))))))

(defun kargu-diff-apply-patch (patch-text)
  "Parse and apply multi-file changes from PATCH-TEXT.
Supports '*** Add File: <path>', '*** Update File: <path>',
and '*** Delete File: <path>' within optional '*** Begin Patch'
and '*** End Patch' envelopes.
Applies edits through the proposal and rollback pipeline.
Returns a formatted summary of applied changes."
  (unless (and (stringp patch-text) (not (string-empty-p (string-trim patch-text))))
    (error "patch text must be a non-empty string"))
  (let* ((lines (split-string (string-trim patch-text) "\n"))
         (ops nil)
         (curr-type nil)
         (curr-file nil)
         (curr-lines nil)
         (flush-op
          (lambda ()
            (when (and curr-type curr-file)
              (push (list :type curr-type :file curr-file :lines (nreverse curr-lines)) ops)
              (setq curr-type nil
                    curr-file nil
                    curr-lines nil)))))
    (dolist (raw lines)
      (let ((line (string-trim-right raw)))
        (cond
         ((or (string-prefix-p "*** Begin Patch" line)
              (string-prefix-p "*** End Patch" line))
          nil)
         ((string-prefix-p "*** Add File:" line)
          (funcall flush-op)
          (setq curr-type 'add
                curr-file (string-trim (substring line 13))))
         ((string-prefix-p "*** Update File:" line)
          (funcall flush-op)
          (setq curr-type 'update
                curr-file (string-trim (substring line 16))))
         ((string-prefix-p "*** Delete File:" line)
          (funcall flush-op)
          (setq curr-type 'delete
                curr-file (string-trim (substring line 16))))
         (curr-type
          (push raw curr-lines)))))
    (funcall flush-op)
    (setq ops (nreverse ops))
    (unless ops
      (error "No valid patch operations found (expected '*** Add File:', '*** Update File:', or '*** Delete File:')"))
    (let (results)
      (dolist (op ops)
        (let* ((type (plist-get op :type))
               (rel (plist-get op :file))
               (file (kargu-diff--resolve rel))
               (op-lines (plist-get op :lines)))
          (pcase type
            ('add
             (let* ((content-lines
                     (mapcar (lambda (l)
                               (if (string-prefix-p "+" l) (substring l 1) l))
                             op-lines))
                    (content (string-join content-lines "\n")))
               (kargu-diff-apply-proposal file content)
               (push (format "Added %s (%d lines)" rel (length content-lines)) results)))
            ('delete
             (when (file-exists-p file)
               (kargu-diff-apply-proposal file ""))
             (push (format "Deleted %s" rel) results))
            ('update
             (let* ((orig (or (kargu-diff--file-text file) ""))
                    (hunk-lines
                     (cl-remove-if (lambda (l)
                                     (or (string-prefix-p "@@" l)
                                         (string-prefix-p "*** Move to:" l)))
                                   op-lines))
                    (old-block
                     (string-join
                      (delq nil
                            (mapcar (lambda (l)
                                      (cond
                                       ((string-prefix-p "-" l) (substring l 1))
                                       ((string-prefix-p "+" l) nil)
                                       ((string-prefix-p " " l) (substring l 1))
                                       (t l)))
                                    hunk-lines))
                      "\n"))
                    (new-block
                     (string-join
                      (delq nil
                            (mapcar (lambda (l)
                                      (cond
                                       ((string-prefix-p "+" l) (substring l 1))
                                       ((string-prefix-p "-" l) nil)
                                       ((string-prefix-p " " l) (substring l 1))
                                       (t l)))
                                    hunk-lines))
                      "\n")))
               (let ((replaced (if (and (not (string-empty-p old-block))
                                        (kargu-diff--count-literal orig old-block))
                                   (kargu-diff--replace-first orig old-block new-block)
                                 orig)))
                 (kargu-diff-apply-proposal file replaced)
                 (push (format "Updated %s" rel) results)))))))
      (format "Patch successfully applied to %d file(s):\n  • %s"
              (length results) (string-join (nreverse results) "\n  • ")))))

(defun kargu-diff--apply-patch-tool (args)
  "Executor for the `apply_patch' tool."
  (or (kargu-diff--mutating-disabled "apply_patch")
      (let ((patch (kargu--tool-arg args "patch" "diff" "content")))
        (if (not (kargu--nonempty patch))
            "ERROR: patch argument is required"
          (condition-case-unless-debug err
              (kargu-diff-apply-patch patch)
            (error (format "ERROR: %s" (error-message-string err))))))))

(defun kargu-diff-register-tools ()
  "Register the diff, edit, write, read and apply_patch tools."
  (kargu-register-tool
   "read_file"
   "Read a source file with numbered lines (\"12 | code\"). ALWAYS call this before edit_file so old_string is copied from the real file. Use from_line/to_line to page through large files."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the file (or output buffer) to read.")))
                      ("from_line" . (("type" . "integer")
                                      ("description" . "First 1-based line to return (inclusive).")))
                      ("to_line" . (("type" . "integer")
                                    ("description" . "Last 1-based line to return (inclusive).")))
                      ("limit" . (("type" . "integer")
                                  ("description" . "Maximum number of lines to return from from_line.")))))
     ("required" . ["file_path"]))
   (lambda (args)
     (let* ((path (kargu--tool-file-path args))
            (from (or (kargu--tool-arg args "from_line" "fromLine")
                      (kargu--tool-arg args "offset")))
            (limit (kargu--tool-arg args "limit"))
            (to (or (kargu--tool-arg args "to_line" "toLine")
                    (and from limit
                         (let ((f (kargu-diff--to-int from))
                               (n (kargu-diff--to-int limit)))
                           (and f n (+ f n -1)))))))
       (if (not (kargu--nonempty path))
           (kargu--tool-missing-file-path args)
         (condition-case-unless-debug err
             (kargu-diff-read-file path from to)
           (error (format "ERROR: %s" (error-message-string err))))))))
  (kargu-register-tool
   "edit_file"
   "Replace an exact unique block of text in an existing file. Best for surgical, localized modifications to minimize tokens and conflicts. Read the file first with read_file, then pass the exact old_string (include enough surrounding lines to make it unique) and the new_string replacement. Use write_file instead if you intend to rewrite the entire file. The human reviews the change in ediff (b accepts a hunk, a keeps the original). After an accepted edit, immediately call lsp_diagnostics on the file."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the file to edit.")))
                      ("old_string" . (("type" . "string")
                                       ("description" . "The exact unique string to replace, copied from read_file without the line-number prefix.")))
                      ("new_string" . (("type" . "string")
                                       ("description" . "The replacement string.")))
                      ("reason" . (("type" . "string")
                                   ("description" . "One-sentence justification of the edit, shown to the human during review.")))))
     ("required" . ["file_path" "old_string" "new_string"]))
   #'kargu-diff--edit-file-tool)
  (kargu-register-tool
   "write_file"
   "Write or rewrite a file completely. Overwrites the entire file with contents (or creates it if it does not exist). Note: for small, localized changes to an existing file, prefer edit_file to save tokens and avoid merge conflicts. Use write_file when replacing the entire file or creating a new file. The human reviews the proposal in ediff before it is saved."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the file to write or create.")))
                      ("contents" . (("type" . "string")
                                     ("description" . "Complete contents of the file.")))
                      ("reason" . (("type" . "string")
                                   ("description" . "One-sentence justification, shown during review.")))))
     ("required" . ["file_path" "contents"]))
   #'kargu-diff--write-file-tool)
  (kargu-register-tool
   "apply_patch"
   "Apply a multi-file unified patch across multiple files in a single tool call. Agent mode only.
Format:
*** Begin Patch
*** Add File: path/to/file.ext
+line1
*** Update File: path/to/file.ext
@@
 context
-old line
+new line
*** Delete File: path/to/file.ext
*** End Patch"
   '(("type" . "object")
     ("properties" . (("patch" . (("type" . "string")
                                  ("description" . "Complete unified patch text with file envelopes.")))))
     ("required" . ["patch"]))
   #'kargu-diff--apply-patch-tool)
  (kargu-register-tool-alias "read" "read_file")
  (kargu-register-tool-alias "edit" "edit_file")
  (kargu-register-tool-alias "write" "write_file")
  (kargu-register-tool-alias "patch" "apply_patch"))

(kargu-diff-register-tools)

;; Apply review_mode from TOML config if present
(when (fboundp 'kargu--config-plist)
  (when-let* ((mode-str (plist-get (kargu--config-plist) :review-mode)))
    (let ((m (intern (downcase (string-trim mode-str)))))
      (when (memq m '(auto blocking async))
        (setq kargu-diff-review-mode m)))))

(provide 'kargu/tools/diff)

;;; kargu/tools/diff.el ends here
