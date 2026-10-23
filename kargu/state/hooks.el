;;; hooks.el --- State change hooks and subscriptions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Event bus and hooks for state changes (mode, provider, model, status).
;; Allows UI components to update reactively without hardcoded circular dependencies.

;;; Code:

(require 'kargu/core/observers)

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
  "Notify every listener that KEY changed to VALUE, with optional DETAIL."
  (kargu-run-observers 'kargu-state-change-hook key value)
  (pcase key
    (:mode
     (kargu-run-observers 'kargu-state-mode-hook value))
    (:provider
     (kargu-run-observers 'kargu-state-provider-hook value))
    (:model
     (kargu-run-observers 'kargu-state-model-hook value))
    (:status
     (kargu-run-observers 'kargu-state-status-hook value detail))))

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

;;; hooks.el ends here
