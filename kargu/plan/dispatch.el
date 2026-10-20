;;; dispatch.el --- Plan review actions and dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; User actions for approving, editing, or rejecting implementation plans.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/plan/buffer)

(defun kargu-plan-view (&optional record)
  "Display RECORD's review buffer, defaulting to the caller's current plan."
  (interactive)
  (let* ((record (or record (kargu-plan-current)))
         (buf (and record (kargu-plan-record-buffer
                           (kargu-plan-assert-current record)))))
    (if (not (and buf (buffer-live-p buf)))
        (message "kargu: no active plan buffer found")
      (let ((win (display-buffer buf '(display-buffer-pop-up-window
                                       display-buffer-use-some-window))))
        (when win
          (select-window win))
        (message "Edit plan freely in memory. Press C-c C-c to approve & apply, C-c C-k to cancel.")))))

(defun kargu-plan--close-window (record)
  "Close the window showing RECORD's review buffer, if any."
  (when-let* ((buf (kargu-plan-record-buffer record))
              (win (and (buffer-live-p buf) (get-buffer-window buf))))
    (quit-window nil win)))

(defun kargu-plan-publish (record event)
  "Notify RECORD's optional presenter of EVENT without changing its decision."
  (unless (memq event '(:ready :approved :rejected))
    (error "Unknown plan presentation event: %S" event))
  (when-let* ((publish (kargu-plan-context-publish (kargu-plan-record-context record))))
    (condition-case err
        (funcall publish record event)
      (error (kargu-log 'warn "Plan presentation failed: %s" (error-message-string err))))))

(defun kargu-plan--dispatch-approved (record plan-text)
  "Send RECORD's PLAN-TEXT through its captured dispatcher, claiming it once."
  (let* ((context (kargu-plan-record-context record))
         (preflight (kargu-plan-context-preflight context))
         (dispatch (kargu-plan-context-dispatch context)) dispatched)
    (unless dispatch
      (user-error "Kargu: plan dispatcher unavailable; the plan is still pending"))
    (when preflight (funcall preflight record))
    (unless (kargu-plan-claim record)
      (user-error "Kargu: this plan was already decided"))
    (unwind-protect
        (progn
          (unless (kargu-contract-assert
                   (lambda (result) (memq result '(nil t)))
                   (funcall dispatch record plan-text))
            (user-error "Kargu: plan startup refused; the plan is still pending"))
          (setq dispatched t))
      (kargu-plan-complete record dispatched))
    (when (eq (kargu-plan-record-state record) :approved)
      (kargu-plan--close-window record)
      (kargu-plan-publish record :approved))))

(defun kargu-plan-approve (&optional record)
  "Approve RECORD, defaulting to the current chat or review buffer's plan."
  (interactive)
  (let* ((record (kargu-plan-assert-current (or record (kargu-plan-current))))
         (plan-text (with-current-buffer (kargu-plan-record-buffer record)
                      (save-restriction
                        (widen)
                        (string-trim (buffer-substring-no-properties (point-min) (point-max)))))))
    (cond
     ((not (kargu-plan-pending-p record))
      (message "kargu: this plan was already decided"))
     ((string-empty-p plan-text)
      (message "kargu: no plan text found to approve"))
     (t
      (kargu-plan--dispatch-approved record plan-text)))))

(defun kargu-plan-reject (&optional record)
  "Reject pending RECORD, defaulting to the caller's current plan."
  (interactive)
  (let ((record (kargu-plan-assert-current (or record (kargu-plan-current)))))
    (if (not (kargu-plan-decline record))
        (message "kargu: this plan was already decided")
      (kargu-plan--close-window record)
      (kargu-plan-publish record :rejected)
      (message "kargu: plan cancelled"))))

(defun kargu-plan-handle-response (report)
  "Prepare an owned plan from REPORT and notify its optional presenter."
  (when-let* ((text (kargu-plan-extract-text report)))
    (let* ((buffer (kargu-plan-setup-buffer text))
           (record (kargu-plan-current buffer)))
      (kargu-plan-publish record :ready))))

(provide 'kargu/plan/dispatch)

;;; dispatch.el ends here
