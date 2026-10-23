;;; selectors.el --- Pure state query selectors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pure selectors for querying the central state store.

;;; Code:

(require 'kargu/state/store)

(defun kargu-state-mode ()
  "Return the current session's operating mode (`ask', `plan', etc.)."
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
  (kargu-application-busy-p))

(defun kargu-state-tokens (&optional session)
  "Return a plist of cumulative tokens derived from SESSION's usage record.
Shape: `(:prompt P :completion C :total T)'."
  (let* ((resolved (kargu-session--resolve session))
         (usage (kargu-session-usage-value resolved))
         (prompt (or (plist-get usage :tokens-in) 0))
         (completion (or (plist-get usage :tokens-out) 0)))
    (list :prompt prompt
          :completion completion
          :total (+ prompt completion))))

(provide 'kargu/state/selectors)

;;; selectors.el ends here
