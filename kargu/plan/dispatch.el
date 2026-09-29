;;; kargu/plan/dispatch.el --- Plan review actions and dispatch -*- lexical-binding: t; -*-

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

(defvar kargu-chat-buffer-name)
(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt))

(defun kargu-plan-view ()
  "Display the in-memory plan buffer in a suitable window for editing."
  (interactive)
  (let ((buf (get-buffer kargu-plan-buffer-name)))
    (if (not (and buf (buffer-live-p buf)))
        (message "kargu: no active plan buffer found")
      (let ((win (display-buffer buf '(display-buffer-pop-up-window
                                       display-buffer-use-some-window))))
        (when win
          (select-window win))
        (message "Edit plan freely in memory. Press C-c C-c to approve & apply, C-c C-k to cancel.")))))

(declare-function kargu-chat-insert "kargu/chat/render" (text &optional face))

(defun kargu-plan--close-window ()
  "Close the window showing the plan buffer, if any."
  (when-let* ((buf (get-buffer kargu-plan-buffer-name))
              (win (and (buffer-live-p buf) (get-buffer-window buf))))
    (quit-window nil win)))

(defun kargu-plan--take-decision ()
  "Claim the pending plan decision; return non-nil the first time only.
A button stays in the transcript after it is used, so a second click
finds no decision to make."
  (prog1 kargu-plan--decision-pending
    (setq kargu-plan--decision-pending nil)))

(defun kargu-plan-approve ()
  "Approve the current in-memory plan and dispatch it to AI in agent mode."
  (interactive)
  (let* ((buf (get-buffer kargu-plan-buffer-name))
         (plan-text (if (and buf (buffer-live-p buf))
                        (with-current-buffer buf
                          (string-trim (buffer-substring-no-properties (point-min) (point-max))))
                      (or kargu-plan--current-plan ""))))
    (cond
     ((not kargu-plan--decision-pending)
      (message "kargu: this plan was already decided"))
     ((string-empty-p plan-text)
      (message "kargu: no plan text found to approve"))
     (t
      (kargu-plan--take-decision)
      (kargu-plan--close-window)
      (kargu-chat-insert "  ✓ [Plan Approved] — Switching to agent mode and applying plan...\n\n"
                          '(:inherit success :weight bold))
      (kargu-set-mode 'agent)
      (let ((prompt (format "Apply the following approved plan step-by-step:\n\n%s" plan-text)))
        (if (fboundp 'kargu-chat-prompt)
            (kargu-chat-prompt prompt)
          (message "kargu-chat-prompt unavailable")))))))

(defun kargu-plan-reject ()
  "Reject and cancel the pending plan."
  (interactive)
  (if (not (kargu-plan--take-decision))
      (message "kargu: this plan was already decided")
    (kargu-plan--close-window)
    (kargu-chat-insert "  ✗ [Plan Rejected] — Plan cancelled.\n\n" 'font-lock-warning-face)
    (message "kargu: plan cancelled")))

(defun kargu-plan--button (label action face help)
  "A transcript button showing LABEL that calls ACTION, drawn with FACE."
  (make-text-button label nil
                    'action (lambda (_) (funcall action))
                    'face face
                    'help-echo help
                    'follow-link t))

(defun kargu-plan-handle-response (report)
  "Render plan approval buttons and populate `*kargu-plan*' for REPORT."
  (let ((plan-text (kargu-plan-extract-text report)))
    (when (and (stringp plan-text) (not (string-empty-p plan-text)))
      (kargu-plan-setup-buffer plan-text)
      (kargu-chat-insert "\n")
      (kargu-chat-insert "  📋 [Plan Ready] — Choose an option below:\n"
                          '(:inherit font-lock-doc-face :weight bold))
      (kargu-chat-insert "     ")
      (kargu-chat-insert
       (kargu-plan--button "[✓ Approve & Apply]" #'kargu-plan-approve
                           '(:inherit success :weight bold)
                           "Approve plan and start autonomous execution in Agent mode"))
      (kargu-chat-insert "   ")
      (kargu-chat-insert
       (kargu-plan--button "[✏ View / Edit Plan]" #'kargu-plan-view
                           '(:inherit warning :weight bold)
                           "Open and edit plan in a side window (in-memory, no disk save)"))
      (kargu-chat-insert "   ")
      (kargu-chat-insert
       (kargu-plan--button "[✗ Reject]" #'kargu-plan-reject
                           '(:inherit error :weight bold)
                           "Reject and cancel plan"))
      (kargu-chat-insert "\n\n")
      (message "kargu plan: click [✓ Approve & Apply], [✏ View / Edit Plan], or [✗ Reject]."))))

(provide 'kargu/plan/dispatch)

;;; kargu/plan/dispatch.el ends here
