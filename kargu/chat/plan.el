;;; plan.el --- Chat adapter for owned implementation plans -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Own chat identity checks, mode preparation, dispatch and plan notices.
;; The plan domain consumes only its captured context and callbacks.

;;; Code:

(require 'kargu/plan)
(require 'kargu/application/coordinator)
(require 'kargu/chat/session)
(require 'kargu/chat/transcript)
(require 'kargu/state/selectors)

(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt &key on-ready))
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-chat--input-text "kargu/chat/prompt" ())

(defun kargu-chat-plan--current-p (record)
  "Return non-nil when RECORD still belongs to the same chat identity."
  (let ((origin (kargu-plan-record-origin record)))
    (and (equal (kargu-plan-record-root record) (kargu-session-project-root origin))
         (equal (kargu-plan-record-session record) (kargu-chat-session-id origin)))))

(defun kargu-chat-plan--preflight (_record)
  "Refuse unavailable dispatch or another active run before claiming a RECORD."
  (unless (fboundp 'kargu-chat-prompt)
    (user-error "Kargu: chat dispatch is unavailable; the plan is still pending"))
  (when (kargu-application-work-active-p)
    (user-error "Kargu: stop the active run before applying a plan")))

(cl-defstruct (kargu-chat-plan-start (:constructor kargu-chat-plan--start))
  "Captured plan revision, draft and mode for one approved dispatch."
  record session selection view-tick draft mode revision text complete)

(defun kargu-chat-plan--draft ()
  "Read the full prompt without narrowing; preserve any unsent draft."
  (save-restriction (widen) (kargu-chat--input-text)))

(defun kargu-chat-plan--check-start (start)
  "Refuse START when its owner, approved revision or unsent draft changed."
  (let ((record (kargu-chat-plan-start-record start)))
    (kargu-plan-assert-current record)
    (unless (and (eq (kargu-chat-plan-start-session start) (kargu-session-context))
                 (eq (kargu-chat-plan-start-selection start) (kargu-selection-context))
                 (= (kargu-chat-plan-start-view-tick start)
                    (with-current-buffer (kargu-plan-record-buffer record)
                      (buffer-chars-modified-tick)))
                 (equal (kargu-chat-plan-start-draft start) (kargu-chat-plan--draft)))
      (user-error "Kargu: approved plan or chat draft changed; approve it again"))))

(defun kargu-chat-plan--restore-mode (start)
  "Restore START's previous mode only while its own mode revision remains."
  (when (and (eq (kargu-chat-plan-start-session start) (kargu-session-context))
             (= (kargu-session-mode-revision (kargu-session-context))
                (1+ (kargu-chat-plan-start-revision start)))
             (eq (kargu-state-mode) 'agent) (not (kargu-loop-running-p)))
    (kargu-state-set-mode (kargu-chat-plan-start-mode start))))

(defun kargu-chat-plan--start-ready (start mode error)
  "Continue START only after MODE preparation, delivering ERROR on refusal."
  (let ((failure error))
    (unless failure
      (condition-case err
          (progn
            (kargu-chat-plan--check-start start)
            (unless (= (kargu-chat-plan-start-revision start)
                       (kargu-session-mode-revision (kargu-session-context)))
              (user-error "Kargu: plan mode selection was superseded"))
            (kargu-state-set-mode mode)
            (kargu-chat-plan--check-start start)
            (unless (and (eq (kargu-state-mode) mode)
                         (= (kargu-session-mode-revision (kargu-session-context))
                            (1+ (kargu-chat-plan-start-revision start))))
              (user-error "Kargu: plan mode publication was superseded"))
            (kargu-chat-prompt
             (format "Apply the following approved plan step-by-step:\n\n%s"
                     (kargu-chat-plan-start-text start))
             :on-ready (lambda (success error)
                         (unless success (kargu-chat-plan--restore-mode start))
                         (funcall (kargu-chat-plan-start-complete start) success error))))
        (error (setq failure (error-message-string err)))))
    (when failure
      (condition-case err (kargu-chat-plan--restore-mode start)
        (error (kargu-log 'warn "Plan mode rollback refused: %s" (error-message-string err)))))
    (when failure (funcall (kargu-chat-plan-start-complete start) nil failure))
    failure))

(defun kargu-chat-plan--dispatch (record plan-text complete)
  "Prepare RECORD's PLAN-TEXT, then report actual startup to COMPLETE."
  (with-current-buffer (kargu-plan-record-origin record)
    (let ((start (kargu-chat-plan--start
                  :record record :session (kargu-session-context)
                  :selection (kargu-selection-context) :mode (kargu-state-mode)
                  :revision (kargu-session-mode-revision (kargu-session-context))
                  :view-tick (with-current-buffer (kargu-plan-record-buffer record)
                               (buffer-chars-modified-tick))
                  :draft (kargu-chat-plan--draft) :text plan-text :complete complete)) failure)
      (kargu-mode-prepare
       'agent (lambda (mode error) (setq failure (kargu-chat-plan--start-ready start mode error))))
      (when failure (user-error "%s" failure)))))

(defun kargu-chat-plan--context (origin)
  "Capture chat ORIGIN's identity and its application adapter callbacks."
  (let ((session (kargu-session-context origin)))
    (kargu-plan-context-create
     :root (kargu-session-project-root origin) :session (kargu-chat-session-id origin)
     :current-p (lambda (record)
                  (and (eq session (kargu-session-context origin))
                       (kargu-chat-plan--current-p record)))
     :preflight #'kargu-chat-plan--preflight
     :dispatch-style :asynchronous
     :dispatch #'kargu-chat-plan--dispatch :publish #'kargu-chat-plan--publish)))

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
