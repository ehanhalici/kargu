;;; stage.el --- Shadow buffer creation and staging logic -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Shadow buffer management and proposal staging logic.
;; Separated from `kargu/tools/diff' for single responsibility.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/core)
(require 'kargu/core/observers)
(require 'kargu/permission)
(require 'kargu/tools/diff/track)

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)
(defvar kargu-diff-after-apply-hook)

(defvar kargu-diff--current-file nil
  "Absolute path of the file reported by `kargu-diff-after-apply-hook'.
Dynamically bound while the hook runs.")

(defvar kargu-diff--active-pre-state nil
  "Pre-edit snapshot state bound around staging a proposal.")

(defvar kargu-diff--batch-defer-commit nil
  "Non-nil while staging a multi-file batch so reviews defer disk commits.")

(declare-function kargu-diff--apply-interactive "kargu/tools/diff/review"
                  (path buf-a original new-content exists callback))
(declare-function kargu-diff--sessions "kargu/tools/diff/review" ())
(declare-function kargu-diff--session-live-p "kargu/tools/diff/review" (session))
(declare-function kargu-diff--reap-stale "kargu/tools/diff/review" (path))
(defvar kargu-diff--sessions)

;;;; Helpers --------------------------------------------------------------

(cl-defstruct (kargu-diff--origin (:constructor kargu-diff--make-origin))
  "Immutable lifetime and canonical target identity captured before review."
  (buffer nil :read-only t) (session nil :read-only t)
  (directory nil :read-only t) (canonical nil :read-only t)
  (run nil :read-only t))

(defun kargu-diff--capture-origin (path)
  "Capture the current edit owner's lifetime and canonical PATH."
  (kargu-diff--make-origin
   :buffer (current-buffer) :session (kargu-session-context)
   :directory default-directory :canonical (file-truename path)
   :run kargu--loop-run))

(defun kargu-diff--validate-origin (state)
  "Reject STATE when its review owner or canonical target was replaced."
  (when-let* ((origin (plist-get state :owner)))
    (let ((buffer (kargu-diff--origin-buffer origin)))
      (unless (and (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (and (eq (kargu-diff--origin-session origin) (kargu-session-context))
                          (equal (kargu-diff--origin-directory origin) default-directory)))
                   (or (null (kargu-diff--origin-run origin))
                       (eq (kargu-diff--origin-run origin) kargu--loop-run))
                   (equal (kargu-diff--origin-canonical origin)
                          (file-truename (plist-get state :path))))
        (error "Conflict: edit owner or target changed before commit")))))

(defun kargu-diff--count-literal (haystack needle)
  "Count non-overlapping occurrences of NEEDLE in HAYSTACK."
  (if (or (not (stringp haystack))
          (not (stringp needle))
          (string-empty-p needle))
      0
    (with-temp-buffer
      (insert haystack)
      (goto-char (point-min))
      (let ((count 0)
            (case-fold-search nil))
        (while (search-forward needle nil t)
          (setq count (1+ count)))
        count))))

(defun kargu-diff--replace-first (haystack old new)
  "Replace the first literal, case-sensitive OLD in HAYSTACK with NEW."
  (with-temp-buffer
    (insert haystack)
    (goto-char (point-min))
    (if (not (let ((case-fold-search nil)) (search-forward old nil t)))
        haystack
      (replace-match new t t)
      (buffer-string))))

(defun kargu-diff--file-text (path)
  "Return the full widened text of PATH from its clean visiting buffer, or disk.
Signal when a visiting buffer has unsaved user edits."
  (let ((buf (find-buffer-visiting path)))
    (cond
     ((buffer-live-p buf)
      (with-current-buffer buf
        (when (buffer-modified-p buf)
          (error "Buffer %s has unsaved modifications; save or revert it before agent edits"
                 (buffer-name buf)))
        (save-restriction
          (widen)
          (buffer-string))))
     ((file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))
     (t nil))))

(defun kargu-diff--capture-pre-state (path)
  "Capture pre-edit snapshot state for PATH without opening or dirtying buffers."
  (let* ((exists (file-exists-p path))
         (buf (find-buffer-visiting path))
         (disk-rev (kargu-diff--disk-revision path)))
    (when (and (buffer-live-p buf) (buffer-modified-p buf))
      (error "Buffer %s has unsaved modifications; save or revert it before agent edits"
             (buffer-name buf)))
    (when (and (buffer-live-p buf) (with-current-buffer buf buffer-read-only))
      (error "Buffer %s is read-only; turn off read-only-mode before proposing edits"
             (buffer-name buf)))
    (when (and (buffer-live-p buf) exists
               (not (verify-visited-file-modtime buf)))
      (error "Buffer %s is out of sync with disk; revert or save it before agent edits"
             (buffer-name buf)))
    (let* ((read-res
            (cond
             ((buffer-live-p buf)
              (with-current-buffer buf
                (cons (save-restriction (widen) (buffer-string))
                      buffer-file-coding-system)))
             (exists
              (with-temp-buffer
                (insert-file-contents path)
                (cons (buffer-string) buffer-file-coding-system)))
             (t (cons "" nil))))
           (baseline (kargu-diff--capture-baseline-diagnostics path)))
      (list :path path
            :owner (kargu-diff--capture-origin path)
            :exists exists
            :had-buffer (and (buffer-live-p buf) t)
            :buffer (and (buffer-live-p buf) buf)
            :original (car read-res)
            :coding (cdr read-res)
            :tick (and (buffer-live-p buf) (buffer-chars-modified-tick buf))
            :disk-revision disk-rev
            :baseline-available (plist-get baseline :available)
            :baseline-diagnostics (plist-get baseline :diagnostics)))))

(defun kargu-diff--validate-pre-state (pre-state)
  "Verify PRE-STATE still matches PATH's current buffer and disk state."
  (kargu-diff--validate-origin pre-state)
  (let* ((path (plist-get pre-state :path))
         (exists (plist-get pre-state :exists))
         (expected-buf (plist-get pre-state :buffer))
         (expected-tick (plist-get pre-state :tick))
         (expected-disk (plist-get pre-state :disk-revision))
         (expected-orig (plist-get pre-state :original))
         (curr-exists (file-exists-p path))
         (curr-buf (find-buffer-visiting path))
         (curr-disk (kargu-diff--disk-revision path)))
    (unless (eq (and exists t) (and curr-exists t))
      (error "Conflict for %s: file existence changed before commit" path))
    (when (and (buffer-live-p curr-buf) (buffer-modified-p curr-buf))
      (error "Conflict for %s: buffer %s has unsaved modifications"
             path (buffer-name curr-buf)))
    (when (and (buffer-live-p curr-buf) (with-current-buffer curr-buf buffer-read-only))
      (error "Conflict for %s: buffer %s is read-only"
             path (buffer-name curr-buf)))
    (when (and (buffer-live-p expected-buf)
               (eq curr-buf expected-buf)
               expected-tick
               (not (eql expected-tick (buffer-chars-modified-tick curr-buf))))
      (error "Conflict for %s: buffer was modified since snapshot" path))
    (when (and exists (not (equal expected-disk curr-disk)))
      (error "Conflict for %s: file changed on disk since snapshot" path))
    (when (buffer-live-p curr-buf)
      (unless (string= (kargu-diff--buffer-full-text curr-buf) (or expected-orig ""))
        (error "Conflict for %s: buffer content differs from snapshot" path)))))

(defun kargu-diff-apply-replace (file-path old-string new-string &optional callback)
  "Replace the unique OLD-STRING in FILE-PATH with NEW-STRING.
The replacement is staged through `kargu-diff-apply-proposal'
using a shadow buffer and ediff.  Signal an error when OLD-STRING is
missing or not unique so the model can re-read and retry.
CALLBACK receives the final review outcome when supplied."
  (unless (and (stringp old-string) (not (string-empty-p old-string)))
    (error "The old_string must be a non-empty string"))
  (unless (stringp new-string)
    (error "The new_string must be a string"))
  (let ((path (kargu-permission-resolve file-path "file")))
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
    (let* ((pre-state (kargu-diff--capture-pre-state path))
           (original (or (plist-get pre-state :original) ""))
           (matches (kargu-diff--count-literal original old-string)))
      (unless (= matches 1)
        (error "The old_string was not found or is not unique (matches: %d); re-read the file with read_file and provide unique context"
               matches))
      (let ((kargu-diff--active-pre-state pre-state))
        (kargu-diff-apply-proposal
         path
         (kargu-diff--replace-first original old-string new-string)
         callback)))))

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
        (saved (plist-get outcome :saved))
        (hook-transformed (plist-get outcome :hook-transformed)))
    (cond
     ((eq status :applied-full)
      (if (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'auto))
          (format "APPLIED: the change to %s has been applied%s%s. Verify it with lsp_diagnostics."
                  path
                  (if saved " and the file is saved" "")
                  (if hook-transformed " (note: save hooks modified the final text)" ""))
        (format "APPLIED: the human accepted the proposal for %s%s%s. Verify it with lsp_diagnostics."
                path
                (if saved " and the file is saved" "")
                (if hook-transformed " (note: save hooks modified the final text)" ""))))
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
     ((eq status :conflict)
      (or (plist-get outcome :message)
          (format "ERROR: conflict while applying edit to %s; nothing was overwritten." path)))
     (t (or (plist-get outcome :message)
            (format "Review of %s finished with status %s." path status))))))

;;;; Shadow buffers -------------------------------------------------------

(defun kargu-diff--shadow-name (path)
  "Return the shadow buffer name for PATH."
  (format "*kargu-shadow:%s*" (file-name-nondirectory path)))

(defun kargu-diff--base-name (path)
  "Return the isolated base buffer name for PATH."
  (format "*kargu-base:%s*" (file-name-nondirectory path)))

(defun kargu-diff--make-shadow (path content)
  "Create a fresh shadow buffer holding CONTENT for PATH.
An existing buffer is never reused or killed, even for the same path.
The new buffer is unfiled, has undo disabled and starts unmodified."
  (let ((buffer (generate-new-buffer (kargu-diff--shadow-name path))))
    (with-current-buffer buffer
      (fundamental-mode)
      (buffer-disable-undo buffer)
      (insert content)
      (set-buffer-modified-p nil))
    buffer))

(defun kargu-diff--make-base (path content)
  "Create a fresh isolated base snapshot buffer holding CONTENT for PATH."
  (let ((buffer (generate-new-buffer (kargu-diff--base-name path))))
    (with-current-buffer buffer
      (fundamental-mode)
      (buffer-disable-undo buffer)
      (insert content)
      (set-buffer-modified-p nil))
    buffer))

;;;; Core: staging and the ediff review -----------------------------------

(defun kargu-diff-apply-proposal (file-path new-content &optional callback)
  "Propose NEW-CONTENT as the full new content of FILE-PATH.
The file is never overwritten blindly:  the proposal is staged in
a shadow buffer and reviewed in ediff with buffer A = an isolated
base snapshot and buffer B = the shadow.  ediff's native
keys decide hunks:  `a' keeps the original hunk, `b' adopts the
proposed hunk, unvisited hunks stay original.  A rollback
snapshot of the pre-edit content is recorded upon commit; quitting
ediff finalizes the review (revalidation, save, change signal, notification).

CALLBACK, when non-nil, is called exactly once with the final
outcome plist (for :staged reviews this happens when the human
quits ediff).  Return value: an outcome plist with :status
:applied-full, :applied-partial, :rejected, :interrupted,
:unchanged or :staged (review pending - async mode, or a postponed
blocking review), plus :file, :saved and a model-facing :message."
  (unless (stringp new-content)
    (error "New-content must be a string"))
  (let* ((path (kargu-permission-resolve file-path "file"))
         (prior (and (boundp 'kargu-diff--sessions)
                     (gethash path kargu-diff--sessions))))
    (when (and prior (fboundp 'kargu-diff--session-live-p) (kargu-diff--session-live-p prior))
      (error "A review is already pending for %s; finish it in ediff (q) first" path))
    (when prior
      (when (fboundp 'kargu-diff--reap-stale)
        (kargu-diff--reap-stale path)))
    (let* ((pre-state (if (and kargu-diff--active-pre-state
                               (equal (plist-get kargu-diff--active-pre-state :path) path))
                          kargu-diff--active-pre-state
                        (kargu-diff--capture-pre-state path)))
           (exists (plist-get pre-state :exists))
           (original (plist-get pre-state :original))
           (buf-a (plist-get pre-state :buffer)))
      (if (string= original new-content)
          (let ((outcome (list :status :unchanged :file path :saved nil)))
            (plist-put outcome :message (kargu-diff--describe outcome))
            (kargu-diff--notify callback outcome path)
            outcome)
        (let ((kargu-diff--active-pre-state pre-state))
          (if (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'auto))
              (kargu-diff--apply-auto path buf-a original new-content exists callback pre-state)
            (if (fboundp 'kargu-diff--apply-interactive)
                (kargu-diff--apply-interactive path buf-a original new-content exists callback)
              (error "kargu-diff--apply-interactive is unavailable"))))))))

(defun kargu-diff--open-proposal-buffer (path)
  "Open or find buffer visiting PATH and verify it is writable and clean."
  (let ((buf (or (find-buffer-visiting path)
                 (let ((enable-local-variables :safe)
                       (enable-dir-local-variables nil)
                       (enable-local-eval nil))
                   (find-file-noselect path)))))
    (when (with-current-buffer buf buffer-read-only)
      (error "Buffer %s is read-only; turn off read-only-mode before proposing edits"
             (buffer-name buf)))
    (when (buffer-modified-p buf)
      (error "Buffer %s has unsaved modifications; save or revert it before agent edits"
             (buffer-name buf)))
    buf))

(defun kargu-diff--write-prepared-content (buffer state content)
  "Write CONTENT to BUFFER using STATE's original coding and save policy."
  (with-current-buffer buffer
    (kargu-diff--replace-buffer-preserving-view buffer content)
    (when-let* ((coding (plist-get state :coding)))
      (setq buffer-file-coding-system coding))
    (set-buffer-modified-p t)
    (when kargu-diff-auto-save
      (save-buffer)
      (when (buffer-modified-p)
        (error "Save did not persist the complete proposal for %s" buffer-file-name)))
    (list :content (kargu-diff--buffer-full-text buffer)
          :saved (and kargu-diff-auto-save t))))

(defun kargu-diff--recover-failed-write (state buffer)
  "Restore STATE after a failed write to BUFFER, preserving foreign disk text."
  (let* ((path (plist-get state :path))
         (original (plist-get state :original))
         (attempted (kargu-diff--buffer-full-text buffer))
         (disk-text (when (file-exists-p path)
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))))
    (unless (or (null disk-text) (equal disk-text original)
                (equal disk-text attempted))
      (error "Conflict recovering %s: external disk content was preserved" path))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-visited-file-modtime)))
    (when (and disk-text
               (or (not (plist-get state :exists))
                   (not (equal disk-text original))))
      (if (plist-get state :exists)
          (let ((coding-system-for-write (or (plist-get state :coding) 'utf-8-unix)))
            (with-temp-buffer (write-region original nil path nil 'silent)))
        (delete-file path)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (set-visited-file-modtime)
        (kargu-diff--replace-buffer-preserving-view buffer original)
        (when-let* ((coding (plist-get state :coding)))
          (setq buffer-file-coding-system coding))
        (set-buffer-modified-p nil)
        (set-visited-file-modtime)))
    (when (and (not (plist-get state :had-buffer)) (buffer-live-p buffer))
      (kill-buffer buffer))))

(defun kargu-diff--record-commit (state buffer result status)
  "Record committed RESULT of STATUS for STATE in BUFFER before notification."
  (let* ((path (plist-get state :path))
         (actual (plist-get result :content))
         (snapshot
          (list :content (plist-get state :original)
                :created-new (not (plist-get state :exists)) :at (current-time)
                :coding (plist-get state :coding)
                :disk-revision (plist-get state :disk-revision)
                :post-content actual
                :post-tick (buffer-chars-modified-tick buffer)
                :post-disk-revision (kargu-diff--disk-revision path)
                :baseline-available (plist-get state :baseline-available)
                :baseline-diagnostics (plist-get state :baseline-diagnostics)))
         (outcome (append (list :status status :file path :snapshot snapshot) result)))
    (puthash path (cons snapshot (gethash path kargu-diff--snapshots))
             kargu-diff--snapshots)
    (puthash path
             (append outcome (list :baseline-available (plist-get state :baseline-available)
                                   :baseline-diagnostics (plist-get state :baseline-diagnostics)))
             kargu-diff--changed)
    (cl-pushnew path kargu-diff--run-modified-files :test #'equal)
    (plist-put outcome :message (kargu-diff--describe outcome))))

(defun kargu-diff--commit-file-content (pre-state final-content &optional status)
  "Validate PRE-STATE and commit FINAL-CONTENT with optional outcome STATUS.
Reconcile save hooks before publishing evidence; notification cannot undo a
committed write.  Failed saves restore only content belonging to this write."
  (kargu-diff--validate-pre-state pre-state)
  (let* ((path (plist-get pre-state :path))
         (parent (file-name-directory path))
         (buffer (or (find-buffer-visiting path)
                     (kargu-diff--open-proposal-buffer path)))
         (result nil))
    (when parent (make-directory parent t))
    (condition-case err
        (setq result (kargu-diff--write-prepared-content buffer pre-state final-content))
      (error
       (kargu-diff--recover-failed-write pre-state buffer)
       (signal (car err) (cdr err))))
    (plist-put result :hook-transformed
               (not (equal final-content (plist-get result :content))))
    (let ((outcome (kargu-diff--record-commit pre-state buffer result
                                           (or status :applied-full)))
          (kargu-diff--current-file path))
      (with-current-buffer buffer
        (kargu-run-observers 'kargu-diff-after-apply-hook))
      outcome)))

(defun kargu-diff--apply-auto (path _buf-a original new-content _exists callback &optional pre-state)
  "Apply NEW-CONTENT at PATH and notify CALLBACK.
ORIGINAL is the rollback text; EXISTS says whether PATH already exists.
PRE-STATE holds the captured snapshot state when already collected."
  (let* ((state (or pre-state (kargu-diff--capture-pre-state path)))
         (outcome (kargu-diff--commit-file-content state new-content :applied-full)))
    (kargu-log 'info "diff: auto-applied %s (%d -> %d bytes)"
               path (length original) (length (or (plist-get outcome :content) new-content)))
    (kargu-diff--notify callback outcome path)
    outcome))

(provide 'kargu/tools/diff/stage)

;;; stage.el ends here
