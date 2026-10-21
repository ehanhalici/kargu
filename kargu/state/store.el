;;; store.el --- Central state store definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Central state store definition and low-level accessors.
;; Encapsulates session mode, model, provider, lifecycle status,
;; and cumulative token usage.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/constants)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)
(require 'kargu/selection)

(defvar kargu--state-store nil
  "Immutable snapshot plist of current application status and session tokens.")

(defun kargu-state-initial ()
  "Return a fresh initial state plist."
  (list :status :idle
        :busy nil
        :prompt-tokens 0
        :completion-tokens 0
        :total-tokens 0))

(defun kargu-state--sync-snapshot ()
  "Rebuild `kargu--state-store' from owned application and session records."
  (let* ((usage (kargu-session-usage-value (kargu-session-context)))
         (prompt (or (plist-get usage :tokens-in) 0))
         (completion (or (plist-get usage :tokens-out) 0)))
    (setq kargu--state-store
          (list :status (kargu-application-current-status)
                :busy (kargu-application-busy-p)
                :prompt-tokens prompt
                :completion-tokens completion
                :total-tokens (+ prompt completion)))))

(defun kargu-state-init ()
  "Initialize or re-initialize the application status and current session state."
  (kargu-application-reset)
  (kargu-selection-reset)
  (let* ((session (kargu-session-context))
         (usage (copy-sequence (kargu-session-usage-value session))))
    (setf (kargu-session-mode-value session) 'ask)
    (setq usage (plist-put usage :tokens-in 0))
    (setq usage (plist-put usage :tokens-out 0))
    (setq usage (plist-put usage :last-prompt-tokens 0))
    (setf (kargu-session-usage-value session) usage))
  (kargu-state--sync-snapshot))

;; Initialize state store immediately
(unless kargu--state-store
  (setq kargu--state-store (kargu-state-initial)))

(defun kargu-state-get (key &optional default)
  "Retrieve the value of KEY from the owned session or application coordinator.
Return DEFAULT when KEY is unknown and unset."
  (pcase key
    (:mode (kargu-session-mode-value (kargu-session-context)))
    (:provider (when-let* ((provider (kargu-selection-provider))) (intern provider)))
    (:model (kargu-selection-model))
    (:reasoning-effort (kargu-selection-effort))
    (:status (kargu-application-current-status))
    (:busy (kargu-application-busy-p))
    (:prompt-tokens
     (or (plist-get (kargu-session-usage-value (kargu-session-context)) :tokens-in) 0))
    (:completion-tokens
     (or (plist-get (kargu-session-usage-value (kargu-session-context)) :tokens-out) 0))
    (:total-tokens
     (+ (kargu-state-get :prompt-tokens) (kargu-state-get :completion-tokens)))
    (_ (let ((val (plist-get kargu--state-store key)))
         (if (and (null val) (not (plist-member kargu--state-store key)))
             default
           val)))))

(defun kargu-state--set (key value)
  "Set KEY to VALUE in its owning session or application coordinator.
Callers outside `kargu/state/transitions' do not write the store."
  (when (memq key '(:provider :model :reasoning-effort))
    (error "Selection writes must use the owned selection API"))
  (pcase key
    (:mode
     (let ((session (kargu-session-context)))
       (setf (kargu-session-mode-value session) value)
       (cl-incf (kargu-session-mode-revision session))))
    (:status
     (kargu-application-set-status value)
     (kargu-state--sync-snapshot))
    (:busy
     (kargu-state--sync-snapshot))
    ((or :prompt-tokens :completion-tokens :total-tokens)
     (kargu-state--sync-snapshot))
    (_
     (setq kargu--state-store
           (plist-put (copy-sequence kargu--state-store) key value))))
  value)

(provide 'kargu/state/store)

;;; store.el ends here
