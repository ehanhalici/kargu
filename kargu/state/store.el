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
(require 'kargu/selection)

(defvar kargu--state-store nil
  "Internal plist holding the single source of truth for Kargu state.")

(defun kargu-state-initial ()
  "Return a fresh initial state plist."
  (list :mode kargu-mode-ask
        :status :idle
        :busy nil
        :prompt-tokens 0
        :completion-tokens 0
        :total-tokens 0))

(defun kargu-state-init ()
  "Initialize or re-initialize the state store."
  (kargu-selection-reset)
  (setq kargu--state-store (kargu-state-initial))
  kargu--state-store)

;; Initialize state store immediately
(unless kargu--state-store
  (setq kargu--state-store (kargu-state-initial)))

(defun kargu-state-get (key &optional default)
  "Retrieve the value of KEY from the central state store, or DEFAULT."
  (pcase key
    (:provider (when-let* ((provider (kargu-selection-provider))) (intern provider)))
    (:model (kargu-selection-model))
    (:reasoning-effort (kargu-selection-effort))
    (_ (let ((val (plist-get kargu--state-store key)))
         (if (and (null val) (not (plist-member kargu--state-store key)))
             default
           val)))))

(defun kargu-state--set (key value)
  "Set KEY to VALUE in the central state store.
Callers outside `kargu/state/transitions' do not write the store."
  (when (memq key '(:provider :model :reasoning-effort))
    (error "Selection writes must use the owned selection API"))
  (setq kargu--state-store
        (plist-put (copy-sequence kargu--state-store) key value))
  value)

(provide 'kargu/state/store)

;;; store.el ends here
