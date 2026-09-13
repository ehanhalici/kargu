;;; kargu/tools/diff/review.el --- Ediff review sessions and interactive interaction -*- lexical-binding: t; -*-

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

(defun kargu-diff--apply-interactive (path buf-a original new-content exists callback)
  "Stage NEW-CONTENT in a shadow buffer and launch interactive ediff review."
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
                        :blocking (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'blocking))
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
                       (let ((ediff-window-setup-function (if (boundp 'kargu-diff-ediff-window-setup-function)
                                                             (or kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain)
                                                           #'ediff-setup-windows-plain))
                             (ediff-split-window-function (if (boundp 'kargu-diff-ediff-split-window-function)
                                                             (or kargu-diff-ediff-split-window-function #'split-window-horizontally)
                                                           #'split-window-horizontally)))
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
    (if (and (boundp 'kargu-diff-review-mode) (eq kargu-diff-review-mode 'blocking))
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
        outcome))))

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
                     (boundp 'kargu-diff-auto-save)
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
            (when (boundp 'kargu-diff-after-apply-hook)
              (run-hooks 'kargu-diff-after-apply-hook))))))
    (unless (or (and (boundp 'kargu-diff-keep-shadow) kargu-diff-keep-shadow)
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

(provide 'kargu/tools/diff/review)

;;; kargu/tools/diff/review.el ends here
