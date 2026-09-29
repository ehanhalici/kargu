;;; kargu/state/store.el --- Central state store definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Central state store definition and low-level accessors.
;; Encapsulates session mode, model, provider, lifecycle status,
;; and cumulative token usage.

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
        :provider nil
        :model nil
        :reasoning-effort nil
        :busy nil
        :prompt-tokens 0
        :completion-tokens 0
        :total-tokens 0))

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

(defun kargu-state--set (key value)
  "Set KEY to VALUE in the central state store.
Callers outside `kargu/state/transitions' do not write the store."
  (setq kargu--state-store (plist-put kargu--state-store key value))
  value)

(provide 'kargu/state/store)

;;; kargu/state/store.el ends here
