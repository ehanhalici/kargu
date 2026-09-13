;;; kargu/state/selectors.el --- Pure state query selectors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pure selectors for querying the central state store.

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

(require 'kargu/state/store)

(defun kargu-state-mode ()
  "Return the currently active operating mode symbol (`ask', `plan', etc.)."
  (kargu-state-get :mode 'ask))

(defun kargu-state-status ()
  "Return the current lifecycle status symbol (`:idle', `:requesting', etc.)."
  (kargu-state-get :status :idle))

(defun kargu-state-provider ()
  "Return the currently active provider symbol."
  (kargu-state-get :provider 'openrouter))

(defun kargu-state-model ()
  "Return the currently active model string identifier."
  (kargu-state-get :model "anthropic/claude-3.5-sonnet"))

(defun kargu-state-reasoning-effort ()
  "Return the active reasoning effort (`low', `medium', `high', or nil)."
  (kargu-state-get :reasoning-effort nil))

(defun kargu-state-thinking-budget ()
  "Return the active thinking budget tokens or nil."
  (kargu-state-get :thinking-budget nil))

(defun kargu-state-busy-p ()
  "Return non-nil if an API request or agent loop is currently active."
  (or (kargu-state-get :busy nil)
      (not (memq (kargu-state-status) '(:idle :stopped :error)))))

(defun kargu-state-loop-run ()
  "Return the currently active loop run plist, or nil."
  (kargu-state-get :loop-run nil))

(defun kargu-state-tokens ()
  "Return a plist of cumulative session tokens.
Shape: `(:prompt P :completion C :total T)'."
  (list :prompt (or (kargu-state-get :prompt-tokens) 0)
        :completion (or (kargu-state-get :completion-tokens) 0)
        :total (or (kargu-state-get :total-tokens) 0)))

(defun kargu-state-context-buffer ()
  "Return the active context buffer or nil."
  (kargu-state-get :context-buffer nil))

(provide 'kargu/state/selectors)

;;; kargu/state/selectors.el ends here
