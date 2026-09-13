;;; kargu/state/hooks.el --- State change hooks and subscriptions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Event bus and hooks for state changes (mode, provider, model, status).
;; Allows UI components to update reactively without hardcoded circular dependencies.

;;; Code:

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

(defvar kargu-state-change-hook nil
  "Hook run whenever any state key changes.
Functions are called with two arguments: (KEY VALUE).")

(defvar kargu-state-mode-hook nil
  "Hook run when `:mode' changes.
Functions are called with one argument: (NEW-MODE).")

(defvar kargu-state-provider-hook nil
  "Hook run when `:provider' changes.
Functions are called with one argument: (NEW-PROVIDER).")

(defvar kargu-state-model-hook nil
  "Hook run when `:model' changes.
Functions are called with one argument: (NEW-MODEL).")

(defvar kargu-state-status-hook nil
  "Hook run when `:status' changes.
Functions are called with two arguments: (NEW-STATUS DETAIL).")

(defun kargu-state-notify (key value &optional detail)
  "Notify all registered listeners that KEY changed to VALUE."
  (run-hook-with-args 'kargu-state-change-hook key value)
  (pcase key
    (:mode
     (run-hook-with-args 'kargu-state-mode-hook value))
    (:provider
     (run-hook-with-args 'kargu-state-provider-hook value))
    (:model
     (run-hook-with-args 'kargu-state-model-hook value))
    (:status
     (run-hook-with-args 'kargu-state-status-hook value detail))))

(defun kargu-state-subscribe (event fn)
  "Subscribe function FN to state EVENT.
EVENT can be `:all', `:mode', `:provider', `:model', or `:status'."
  (pcase event
    (:all (add-hook 'kargu-state-change-hook fn))
    (:mode (add-hook 'kargu-state-mode-hook fn))
    (:provider (add-hook 'kargu-state-provider-hook fn))
    (:model (add-hook 'kargu-state-model-hook fn))
    (:status (add-hook 'kargu-state-status-hook fn))
    (_ (error "Unknown state event: %s" event))))

(defun kargu-state-unsubscribe (event fn)
  "Unsubscribe function FN from state EVENT."
  (pcase event
    (:all (remove-hook 'kargu-state-change-hook fn))
    (:mode (remove-hook 'kargu-state-mode-hook fn))
    (:provider (remove-hook 'kargu-state-provider-hook fn))
    (:model (remove-hook 'kargu-state-model-hook fn))
    (:status (remove-hook 'kargu-state-status-hook fn))
    (_ (error "Unknown state event: %s" event))))

(provide 'kargu/state/hooks)

;;; kargu/state/hooks.el ends here
