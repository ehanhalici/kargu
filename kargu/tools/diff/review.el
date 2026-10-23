;;; review.el --- Ediff review sessions and interactive interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Ediff review session lifecycle, interactive approval, and window configuration management.
;; Separated from `kargu/tools/diff' for single responsibility.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ediff)

(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/tools/diff/context)
(require 'kargu/tools/diff/track)
(require 'kargu/tools/diff/stage)

(defvar ediff-buffer-A)                  ; buffer-local in ediff control buffers
(declare-function ediff-really-quit "ediff-util")

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)
(defvar kargu-diff-keep-shadow)
(defvar kargu-diff-ediff-window-setup-function)
(defvar kargu-diff-ediff-split-window-function)
(defvar kargu-diff-after-apply-hook)

;;;; Review sessions ------------------------------------------------------

(defvar kargu-diff--sessions (kargu-edit-service-reviews (kargu-diff--get-default-service))
  "Pending review sessions:  absolute path -> session plist.
Keys of a session plist:  :path, :buffer-a, :shadow-buffer,
:original, :proposal, :created-new, :callback,
:ediff-control, :outcome.  Owned by `kargu-edit-service'.")

(defun kargu-diff--session-live-p (session)
  "Return non-nil when SESSION's ediff review may still be running.
The ediff control buffer decides; a missing control reference
falls back to the shadow buffer's liveness."
  (let ((control (plist-get session :ediff-control)))
    (if control
        (buffer-live-p control)
      (buffer-live-p (plist-get session :shadow-buffer)))))

(defun kargu-diff--maybe-drop-hook (&optional service)
  "Remove ediff quit hook when no reviews are pending on optional SERVICE."
  (when (= 0 (hash-table-count (kargu-diff--service-reviews service)))
    (remove-hook 'ediff-quit-hook #'kargu-diff--ediff-quit)))

(defun kargu-diff--reap-stale (path &optional service)
  "Clean up an abandoned (never finalized) review for PATH on optional SERVICE.
Abandonment means the ediff control buffer died without running
our quit hook, e.g. it was killed directly."
  (let ((session (gethash path (kargu-diff--service-reviews service))))
    (when session
      (kargu-diff--abort-session session t service)
      (kargu-log 'warn "diff: dropped abandoned review for %s" path))))

(defun kargu-diff--close-review-control (control)
  "Close review CONTROL without running its completion hook."
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
           (kill-buffer control)))))))

(defun kargu-diff--abort-session (session &optional silent service)
  "Cancel review SESSION on SERVICE; omit notification when SILENT is non-nil."
  (let* ((path (plist-get session :path))
         (base (plist-get session :base-buffer))
         (shadow (plist-get session :shadow-buffer))
         (control (plist-get session :ediff-control))
         (callback (plist-get session :callback))
         (reviews (kargu-diff--service-reviews service))
         (svc (or service (kargu-diff--current-service))))
    (when (and path (eq session (gethash path reviews)))
      (remhash path reviews))
    (kargu-diff--close-review-control control)
    (dolist (buf (list base shadow))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)
        (when svc (kargu-edit-service-unregister-buffer svc buf))))
    (when-let* ((wconfig (plist-get session :window-config)))
      (kargu-diff--restore-wconfig wconfig))
    (let ((outcome (list :status :interrupted :file path :saved nil)))
      (plist-put outcome :message (kargu-diff--describe outcome))
      (plist-put session :outcome outcome)
      (unless silent
        (kargu-diff--notify callback outcome path)
        (kargu-log 'warn "diff: review interrupted for %s" path))
      outcome)))

(defun kargu-diff-abort-all-sessions (&optional service)
  "Silently cancel every open review on optional SERVICE and restore files.
Called when a run ends without its answer, so no ediff outlives its run."
  (let (sessions)
    (maphash (lambda (_path session) (push session sessions))
             (kargu-diff--service-reviews service))
    (dolist (session sessions)
      (kargu-diff--abort-session session t service))))

(defun kargu-diff-pending-reviews (&optional service)
  "Message the agent reviews that are still open in ediff on optional SERVICE."
  (interactive)
  (let ((paths nil))
    (maphash (lambda (path session)
               (when (kargu-diff--session-live-p session)
                 (push path paths)))
             (kargu-diff--service-reviews service))
    (if (null paths)
        (message "kargu: no pending reviews")
      (message "kargu pending reviews: %s"
               (string-join (nreverse paths) ", ")))))

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
    (let* ((ediff-window-setup-function (if (boundp 'kargu-diff-ediff-window-setup-function)
                                            (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain)
                                          #'ediff-setup-windows-plain))
           (ediff-split-window-function (if (boundp 'kargu-diff-ediff-split-window-function)
                                            (or kargu-diff-ediff-split-window-function #'split-window-horizontally)
                                          #'split-window-horizontally))
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

(defun kargu-diff-review (&optional file-path)
  "Review FILE-PATH against its pre-agent snapshot in Ediff.
Buffer A holds the original text and buffer B the current file.
Use the Ediff command `ediff-copy-A-to-B' to revert individual hunks."
  (interactive
   (list (let ((paths (or (and (boundp 'kargu-diff--run-modified-files)
                               kargu-diff--run-modified-files)
                          (kargu-diff-snapshot-paths))))
           (if paths
               (completing-read "Review file diff in ediff: " paths nil t
                                nil nil (car paths))
             (user-error "No modified files or rollback snapshots available")))))
  (let* ((path (kargu-permission-resolve (or file-path
                                             (car (or (and (boundp 'kargu-diff--run-modified-files)
                                                           kargu-diff--run-modified-files)
                                                      (kargu-diff-snapshot-paths))))
                                         "file"))
         (stack (gethash path kargu-diff--snapshots)))
    (unless stack
      (user-error "No rollback snapshot recorded for %s" path))
    (let* ((orig-snap (car (last stack)))
           (original (plist-get orig-snap :content)))
      (kargu-diff--rollback-review path original))))

(defun kargu-diff--setup-ediff-control (control path wconfig)
  "Configure review CONTROL for PATH, restoring WCONFIG after completion."
  (let ((service (kargu-diff--current-service))
        (ctrl-buf (if (bufferp control)
                      control
                    (and (stringp control) (get-buffer control)))))
    (when (bufferp ctrl-buf)
      (with-current-buffer ctrl-buf
        (setq-local kargu-diff--active-service service)
        (add-hook 'ediff-quit-hook #'kargu-diff--ediff-quit nil t)
        (add-hook 'ediff-after-quit-hook-internal
                  (lambda () (kargu-diff--restore-wconfig wconfig))
                  nil t)
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (when (and (not (kargu-edit-service-closed-p service))
                               (gethash path (kargu-edit-service-reviews service)))
                      (kargu-diff--ediff-quit))
                    (kargu-diff--restore-wconfig wconfig))
                  nil t)))
    ctrl-buf))

(defun kargu-diff--open-review-control (path base shadow)
  "Start an Ediff review for PATH using isolated BASE and SHADOW buffers."
  (condition-case-unless-debug err
      (let ((ediff-window-setup-function (if (boundp 'kargu-diff-ediff-window-setup-function)
                                             (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain)
                                           #'ediff-setup-windows-plain))
            (ediff-split-window-function (if (boundp 'kargu-diff-ediff-split-window-function)
                                             (or kargu-diff-ediff-split-window-function #'split-window-horizontally)
                                           #'split-window-horizontally)))
        (ediff-buffers base shadow))
    (error
     (remhash path kargu-diff--sessions)
     (dolist (buf (list base shadow))
       (when (buffer-live-p buf) (kill-buffer buf)))
     (kargu-diff--maybe-drop-hook)
     (error "Could not start ediff review: %s"
            (error-message-string err)))))

(cl-defun kargu-diff--apply-interactive
    (path buf-a original new-content exists callback &optional pre-state defer-commit)
  "Review NEW-CONTENT for PATH using isolated base and shadow snapshot buffers.
BUF-A is the optional live visiting buffer; ORIGINAL is the initial content;
EXISTS indicates whether PATH exists on disk; CALLBACK receives the outcome.
PRE-STATE holds the pre-edit snapshot state; when DEFER-COMMIT is non-nil,
finalizing the review returns `:decided-content' without writing to disk."
  (let* ((wconfig (current-window-configuration))
         (base (kargu-diff--make-base path original))
         (shadow (kargu-diff--make-shadow path new-content))
         (defer (or defer-commit
                    (and (boundp 'kargu-diff--batch-defer-commit)
                         kargu-diff--batch-defer-commit)))
         (state (or pre-state
                    (and (boundp 'kargu-diff--active-pre-state)
                         (equal (plist-get kargu-diff--active-pre-state :path) path)
                         kargu-diff--active-pre-state)
                    (kargu-diff--capture-pre-state path)))
         (session (list :path path
                        :buffer-a base
                        :base-buffer base
                        :target-buffer buf-a
                        :shadow-buffer shadow
                        :original original
                        :proposal new-content
                        :created-new (not exists)
                        :pre-state state
                        :defer-commit defer
                        :callback callback
                        :window-config wconfig
                        :outcome nil)))
    (puthash path session (kargu-diff--service-reviews))
    (kargu-log 'info "diff: proposal staged for %s (%d -> %d bytes)"
               path (length original) (length new-content))
    (when (fboundp 'kargu-notify)
      (kargu-notify 'permission))
    (let ((control (kargu-diff--open-review-control path base shadow)))
      (plist-put session :ediff-control (kargu-diff--setup-ediff-control control path wconfig)))
    (let ((outcome (list :status :staged :file path :saved nil)))
      (plist-put outcome :message (kargu-diff--describe outcome))
      outcome)))

(defun kargu-diff--ediff-quit ()
  "Finalize the agent review whose ediff session just ended.
Installed on `ediff-quit-hook' while reviews are pending; runs in
the ediff control buffer right before it dies.  Identifies the
associated session by looking at ediff's buffer A and B."
  (let* ((buf-a (and (boundp 'ediff-buffer-A) ediff-buffer-A))
         (buf-b (and (boundp 'ediff-buffer-B) ediff-buffer-B))
         (match nil))
    (maphash (lambda (_path session)
               (when (and (not match)
                          (or (eq (plist-get session :base-buffer) buf-a)
                              (eq (plist-get session :buffer-a) buf-a)
                              (eq (plist-get session :shadow-buffer) buf-b)))
                 (setq match session)))
             (kargu-diff--service-reviews))
    (when match
      (kargu-diff--finalize match))
    (kargu-diff--maybe-drop-hook)))

(defun kargu-diff--evaluate-base-decision (base original proposal)
  "Compare isolated BASE buffer to ORIGINAL and PROPOSAL.
Return (STATUS . DECIDED-CONTENT)."
  (if (not (buffer-live-p base))
      (cons :rejected original)
    (with-current-buffer base
      (let* ((final (save-restriction (widen) (buffer-string)))
             (status (cond
                      ((string= final original) :rejected)
                      ((string= final proposal) :applied-full)
                      (t :applied-partial))))
        (cons status final)))))

(defun kargu-diff--schedule-post-review-cleanup (base shadow wconfig)
  "Schedule deferred cleanup of BASE and SHADOW buffers and restore WCONFIG."
  (let ((svc (kargu-diff--current-service)))
    (when (buffer-live-p base)
      (let ((timer (run-at-time 0 nil
                                (lambda (buf)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf (set-buffer-modified-p nil))
                                    (kill-buffer buf)))
                                base)))
        (when (and svc timer)
          (kargu-edit-service-register-timer svc timer))))
    (unless (or (and (boundp 'kargu-diff-keep-shadow) kargu-diff-keep-shadow)
                (not (buffer-live-p shadow)))
      (let ((timer (run-at-time 0 nil
                                (lambda (buf)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf (set-buffer-modified-p nil))
                                    (kill-buffer buf)))
                                shadow)))
        (when (and svc timer)
          (kargu-edit-service-register-timer svc timer))))
    (when-let* ((cfg wconfig))
      (let ((timer (run-at-time 0 nil
                                (lambda (c)
                                  (when (window-configuration-p c)
                                    (set-window-configuration c)))
                                cfg)))
        (when (and svc timer)
          (kargu-edit-service-register-timer svc timer))))))

(defun kargu-diff--finalize (session)
  "Finalize SESSION only in the service captured before its review."
  (let* ((state (plist-get session :pre-state))
         (origin (plist-get state :owner))
         (service (and origin (kargu-diff--origin-service origin))))
    (kargu-diff-with-service (or service (kargu-diff--current-service))
      (kargu-diff--finalize-owned session))))

(defun kargu-diff--finalize-owned (session)
  "Finish the review of SESSION and return the outcome plist.
When `:defer-commit' is nil and hunks were accepted, commits the decided
content after revalidating `:pre-state'.  Notifies the session callback
and schedules base/shadow cleanup."
  (let* ((path (plist-get session :path))
         (base (or (plist-get session :base-buffer) (plist-get session :buffer-a)))
         (shadow (plist-get session :shadow-buffer))
         (original (plist-get session :original))
         (proposal (plist-get session :proposal))
         (pre-state (plist-get session :pre-state))
         (defer-commit (plist-get session :defer-commit))
         (callback (plist-get session :callback))
         (decision (kargu-diff--evaluate-base-decision base original proposal))
         (status (car decision))
         (decided-content (cdr decision))
         (reviews (kargu-diff--service-reviews))
         (outcome nil))
    (remhash path reviews)
    (kargu-diff--maybe-drop-hook)
    (cond
     ((or defer-commit (not (memq status '(:applied-full :applied-partial))))
      (setq outcome (list :status status
                          :file path
                          :saved nil
                          :deferred (and defer-commit t)
                          :decided-content decided-content
                          :pre-state pre-state))
      (plist-put outcome :message (kargu-diff--describe outcome)))
     (t
      (condition-case err
          (setq outcome (kargu-diff--commit-file-content pre-state decided-content status))
        (error
         (setq outcome
               (list :status :conflict
                     :file path
                     :saved nil
                     :message (format "ERROR: %s" (error-message-string err))))))))
    (plist-put session :outcome outcome)
    (kargu-diff--schedule-post-review-cleanup
     base shadow (plist-get session :window-config))
    (kargu-diff--notify callback outcome path)
    outcome))

(provide 'kargu/tools/diff/review)

;;; review.el ends here
