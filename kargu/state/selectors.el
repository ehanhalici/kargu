;;; kargu/state/selectors.el --- Pure state query selectors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pure selectors for querying the central state store.

;;; Code:

(require 'kargu/state/store)

(defun kargu-state-mode ()
  "Return the currently active operating mode symbol (`ask', `plan', etc.).
The state store is the only place the mode lives."
  (kargu-state-get :mode 'ask))

(defun kargu-state-status ()
  "Return the current lifecycle status symbol (`:idle', `:requesting', etc.)."
  (kargu-state-get :status :idle))

(defun kargu-state-provider ()
  "Return the currently active provider symbol, or nil when unset."
  (kargu-state-get :provider))

(defun kargu-state-model ()
  "Return the currently active model string, or nil when unset."
  (kargu-state-get :model))

(defun kargu-state-reasoning-effort ()
  "Return the active reasoning effort symbol, or nil."
  (kargu-state-get :reasoning-effort nil))

(defun kargu-state-busy-p ()
  "Return non-nil if an API request or agent loop is currently active."
  (or (kargu-state-get :busy nil)
      (not (memq (kargu-state-status) '(:idle :stopped :error :done :limit :pause)))))

(defun kargu-state-tokens ()
  "Return a plist of cumulative session tokens.
Shape: `(:prompt P :completion C :total T)'."
  (list :prompt (or (kargu-state-get :prompt-tokens) 0)
        :completion (or (kargu-state-get :completion-tokens) 0)
        :total (or (kargu-state-get :total-tokens) 0)))

(provide 'kargu/state/selectors)

;;; kargu/state/selectors.el ends here
