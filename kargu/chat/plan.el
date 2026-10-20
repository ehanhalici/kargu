;;; plan.el --- Chat adapter for owned implementation plans -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Own chat identity checks, mode preparation, dispatch and plan notices.
;; The plan domain consumes only its captured context and callbacks.

;;; Code:

(require 'kargu/plan)
(require 'kargu/chat/session)
(require 'kargu/chat/transcript)
(require 'kargu/state/selectors)

(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt))
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-set-mode "kargu/core" (mode))

(defun kargu-chat-plan--current-p (record)
  "Return non-nil when RECORD still belongs to the same chat identity."
  (let ((origin (kargu-plan-record-origin record)))
    (and (equal (kargu-plan-record-root record) (kargu-session-project-root origin))
         (equal (kargu-plan-record-session record) (kargu-chat-session-id origin)))))

(defun kargu-chat-plan--preflight (_record)
  "Refuse unavailable dispatch or another active run before claiming a RECORD."
  (unless (fboundp 'kargu-chat-prompt)
    (user-error "Kargu: chat dispatch is unavailable; the plan is still pending"))
  (when (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (user-error "Kargu: stop the active run before applying a plan")))

(defun kargu-chat-plan--dispatch (record plan-text)
  "Dispatch RECORD's PLAN-TEXT, restoring mode on a refused startup."
  (let ((mode (kargu-state-mode)) dispatched)
    (unwind-protect
        (with-current-buffer (kargu-plan-record-origin record)
          (kargu-set-mode 'agent)
          (kargu-plan-assert-current record)
          (kargu-chat-prompt
           (format "Apply the following approved plan step-by-step:\n\n%s" plan-text))
          (setq dispatched t))
      (unless dispatched
        (when (and (buffer-live-p (kargu-plan-record-origin record))
                   (not (kargu-loop-running-p))
                   (eq (kargu-state-mode) 'agent) (not (eq mode 'agent)))
          (with-current-buffer (kargu-plan-record-origin record)
            (kargu-set-mode mode)))))
    dispatched))

(defun kargu-chat-plan--context (origin)
  "Capture chat ORIGIN's identity and its application adapter callbacks."
  (kargu-plan-context-create
   :root (kargu-session-project-root origin) :session (kargu-chat-session-id origin)
   :current-p #'kargu-chat-plan--current-p :preflight #'kargu-chat-plan--preflight
   :dispatch #'kargu-chat-plan--dispatch :publish #'kargu-chat-plan--publish))

(defun kargu-chat-plan-install ()
  "Install this context adapter idempotently at application composition."
  (advice-add 'kargu-plan-context-for-buffer :override #'kargu-chat-plan--context))

(defun kargu-chat-plan--publish (record event)
  "Present RECORD's lifecycle EVENT in its owning chat only."
  (pcase event
    (:ready (kargu-chat-plan--ready record))
    (:approved
     (kargu-chat-insert-into (kargu-plan-record-origin record)
                             "  ✓ [Plan Approved] — Dispatched in agent mode.\n\n"
                             '(:inherit success :weight bold)))
    (:rejected
     (kargu-chat-insert-into (kargu-plan-record-origin record)
                             "  ✗ [Plan Rejected] — Plan cancelled.\n\n"
                             'font-lock-warning-face))))

(cl-defun kargu-chat-plan--button (label &key action face help)
  "Build a LABEL button invoking ACTION with FACE and HELP text."
  (make-text-button label nil
                    'action (lambda (_) (funcall action))
                    'face face
                    'help-echo help
                    'follow-link t))

(defun kargu-chat-plan--ready (record)
  "Render decision buttons for the captured RECORD, never a later plan."
  (kargu-chat-insert-into
   (kargu-plan-record-origin record)
   (concat
    "\n" (propertize "  📋 [Plan Ready] — Choose an option below:\n"
                     'face '(:inherit font-lock-doc-face :weight bold)) "     "
    (kargu-chat-plan--button
     "[✓ Approve & Apply]" :action (lambda () (kargu-plan-approve record))
     :face '(:inherit success :weight bold)
     :help "Approve plan and start autonomous execution in Agent mode") "   "
    (kargu-chat-plan--button
     "[✏ View / Edit Plan]" :action (lambda () (kargu-plan-view record))
     :face '(:inherit warning :weight bold)
     :help "Open and edit plan in a side window (in-memory, no disk save)") "   "
    (kargu-chat-plan--button
     "[✗ Reject]" :action (lambda () (kargu-plan-reject record))
     :face '(:inherit error :weight bold) :help "Reject and cancel plan") "\n\n"))
  (message "Kargu plan: choose Approve & Apply, View / Edit Plan, or Reject."))

(defun kargu/chat/plan-unload-function ()
  "Refuse unloading while captured plans still reference this adapter."
  (when (seq-some
         (lambda (buffer)
           (when-let* ((record (kargu-plan-current buffer)))
             (eq (kargu-plan-context-dispatch (kargu-plan-record-context record))
                 #'kargu-chat-plan--dispatch))) (buffer-list))
    (user-error "Kargu: close the owned plans before unloading their chat adapter"))
  (advice-remove 'kargu-plan-context-for-buffer #'kargu-chat-plan--context)
  nil)

(provide 'kargu/chat/plan)
;;; plan.el ends here
