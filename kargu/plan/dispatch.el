;;; dispatch.el --- Plan review actions and dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; User actions for approving, editing, or rejecting implementation plans.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/plan/buffer)
(require 'kargu/state/selectors)

(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt))
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-chat-insert-into "kargu/chat/transcript" (buffer text &optional face))

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

(defun kargu-plan--dispatch-approved (record plan-text)
  "Dispatch RECORD's PLAN-TEXT, restoring its decision if startup fails."
  (unless (fboundp 'kargu-chat-prompt)
    (user-error "Kargu: chat dispatch is unavailable; the plan is still pending"))
  (when (kargu-loop-running-p)
    (user-error "Kargu: stop the active run before applying a plan"))
  (let ((mode (kargu-state-mode))
        (dispatched nil))
    (unless (kargu-plan-claim record)
      (user-error "Kargu: this plan was already decided"))
    (unwind-protect
        (progn
          (with-current-buffer (kargu-plan-record-origin record)
            (kargu-set-mode 'agent)
            (kargu-plan-assert-current record)
            (kargu-chat-prompt
             (format "Apply the following approved plan step-by-step:\n\n%s" plan-text)))
          (setq dispatched t))
      (kargu-plan-complete record dispatched)
      (unless dispatched
        (when (and (buffer-live-p (kargu-plan-record-origin record))
                   (not (kargu-loop-running-p))
                   (eq (kargu-state-mode) 'agent)
                   (not (eq mode 'agent)))
          (with-current-buffer (kargu-plan-record-origin record)
            (kargu-set-mode mode)))))
    (kargu-plan--close-window record)
    (kargu-chat-insert-into
     (kargu-plan-record-origin record)
     "  ✓ [Plan Approved] — Dispatched in agent mode.\n\n"
     '(:inherit success :weight bold))))

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
      (kargu-chat-insert-into (kargu-plan-record-origin record)
                              "  ✗ [Plan Rejected] — Plan cancelled.\n\n" 'font-lock-warning-face)
      (message "kargu: plan cancelled"))))

(cl-defun kargu-plan--button (label &key action face help)
  "Build a LABEL button invoking ACTION with FACE and HELP text."
  (make-text-button label nil
                    'action (lambda (_) (funcall action))
                    'face face
                    'help-echo help
                    'follow-link t))

(defun kargu-plan-handle-response (report)
  "Render plan approval buttons and populate `*kargu-plan*' for REPORT."
  (let ((plan-text (kargu-plan-extract-text report)))
    (when (and (stringp plan-text) (not (string-empty-p plan-text)))
      (let* ((buffer (kargu-plan-setup-buffer plan-text))
             (record (kargu-plan-current buffer))
             (origin (kargu-plan-record-origin record)))
        (kargu-chat-insert-into origin "\n")
        (kargu-chat-insert-into origin "  📋 [Plan Ready] — Choose an option below:\n"
                                '(:inherit font-lock-doc-face :weight bold))
        (kargu-chat-insert-into origin "     ")
        (kargu-chat-insert-into origin
                                (kargu-plan--button "[✓ Approve & Apply]" :action (lambda () (kargu-plan-approve record))
                                                    :face '(:inherit success :weight bold)
                                                    :help "Approve plan and start autonomous execution in Agent mode"))
        (kargu-chat-insert-into origin "   ")
        (kargu-chat-insert-into origin
                                (kargu-plan--button "[✏ View / Edit Plan]" :action (lambda () (kargu-plan-view record))
                                                    :face '(:inherit warning :weight bold)
                                                    :help "Open and edit plan in a side window (in-memory, no disk save)"))
        (kargu-chat-insert-into origin "   ")
        (kargu-chat-insert-into origin
                                (kargu-plan--button "[✗ Reject]" :action (lambda () (kargu-plan-reject record))
                                                    :face '(:inherit error :weight bold)
                                                    :help "Reject and cancel plan"))
        (kargu-chat-insert-into origin "\n\n")
        (message "kargu plan: click [✓ Approve & Apply], [✏ View / Edit Plan], or [✗ Reject].")))))

(provide 'kargu/plan/dispatch)

;;; dispatch.el ends here
