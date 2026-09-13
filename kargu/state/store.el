;;; kargu/state/store.el --- Central state store definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Central state store definition and low-level accessors.
;; Encapsulates session mode, model, provider, lifecycle status,
;; loop execution state, and cumulative token usage.

;;; Code:

(require 'cl-lib)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
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

(require 'kargu/contract/constants)

(defvar kargu--state-store nil
  "Internal plist holding the single source of truth for Kargu state.")

(defun kargu-state-initial ()
  "Return a fresh initial state plist."
  (list :mode kargu-mode-ask
        :status :idle
        :provider 'openrouter
        :model "anthropic/claude-3.5-sonnet"
        :reasoning-effort nil
        :thinking-budget nil
        :busy nil
        :loop-run nil
        :prompt-tokens 0
        :completion-tokens 0
        :total-tokens 0
        :context-buffer nil))

(defun kargu-state-init ()
  "Initialize or re-initialize the state store."
  (setq kargu--state-store (kargu-state-initial))
  kargu--state-store)

;; Initialize state store immediately
(unless kargu--state-store
  (kargu-state-init))

(defun kargu-state-get (key &optional default)
  "Retrieve the value of KEY from the central state store, or DEFAULT."
  (let ((val (plist-get kargu--state-store key)))
    (if (and (null val) (not (plist-member kargu--state-store key)))
        default
      val)))

(defun kargu-state-set (key value)
  "Set KEY to VALUE in the central state store."
  (setq kargu--state-store (plist-put kargu--state-store key value))
  value)

(defun kargu-state-update (key fn)
  "Update KEY in the central state store by applying FN to its current value."
  (let* ((curr (kargu-state-get key))
         (new-val (funcall fn curr)))
    (kargu-state-set key new-val)))

(defun kargu-state-all ()
  "Return a copy of the entire state plist."
  (copy-sequence kargu--state-store))

(provide 'kargu/state/store)

;;; kargu/state/store.el ends here
