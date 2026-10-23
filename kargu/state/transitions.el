;;; transitions.el --- Validated state transitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; State transition functions with precondition validation and event notification.
;; Ensures invalid states cannot be entered.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/types)
(require 'kargu/contract/assert)
(require 'kargu/state/store)
(require 'kargu/state/selectors)
(require 'kargu/state/hooks)

(defconst kargu-state--valid-statuses
  '(:idle :starting :running :requesting :streaming :waiting-model
    :executing-tool :executing-tools :waiting-approval :verifying
    :compacting :pause :done :limit :stopped :error :closing :resetting)
  "List of valid lifecycle statuses for the Kargu state machine.")

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-state--set "kargu/state/store" (key value))

(defvar kargu-state-before-mode-change-hook nil
  "Functions validating a requested mode before the state is changed.
Each function receives the mode and may signal a refusal.")

(defun kargu-state-check-mode (mode)
  "Validate MODE and admission, including reentrant preparation hooks."
  (kargu-contract-assert #'kargu-contract-mode-p mode
                         "Invalid kargu mode: %S (expected one of %s)"
                         mode kargu-all-modes)
  (when (kargu-application-work-active-p)
    (user-error "Kargu: cannot change mode while an agent run is in progress (M-x kargu-loop-stop)"))
  (let ((origin (current-buffer)) (owner (kargu-session-context))
        (previous (kargu-session-mode-revision (kargu-session-context)))
        (intent (kargu-session-mode-request (kargu-session-context))))
    (run-hook-with-args 'kargu-state-before-mode-change-hook mode)
    (unless (and (eq origin (current-buffer))
                 (eq owner (kargu-session-context origin))
                 (= previous (kargu-session-mode-revision owner))
                 (eq intent (kargu-session-mode-request owner))
                 (not (kargu-application-work-active-p)))
      (user-error "Kargu: mode preparation was superseded")))
  mode)

(defun kargu-state-set-mode (mode)
  "Commit validated MODE to the current session and notify observers."
  (kargu-state-check-mode mode)
  (kargu-state--set :mode mode)
  (kargu-state-notify :mode mode)
  mode)

(defun kargu-state-set-provider (provider)
  "Set the active PROVIDER symbol."
  (kargu-contract-assert #'symbolp provider "PROVIDER must be a symbol: %S" provider)
  (kargu-selection-update :provider (and provider (symbol-name provider)))
  provider)

(defun kargu-state-set-model (model)
  "Set the active MODEL string identifier."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p model
                         "MODEL must be a non-empty string: %S" model)
  (kargu-selection-update :model model)
  model)

(defun kargu-state-clear-model ()
  "Clear the active model."
  (kargu-selection-update :model nil)
  nil)

(defun kargu-state-set-reasoning-effort (effort)
  "Set the active reasoning EFFORT to a symbol from the model API, or nil."
  (unless (or (null effort) (symbolp effort))
    (error "Invalid reasoning effort: %S (expected a symbol or nil)" effort))
  (kargu-selection-update :effort effort)
  effort)

(defun kargu-state-transition-status (new-status &optional detail)
  "Transition the state machine to NEW-STATUS with optional DETAIL.
Validates that NEW-STATUS is a known status and derives `:busy'."
  (unless (memq new-status kargu-state--valid-statuses)
    (error "Invalid lifecycle status: %S (expected one of %s)"
           new-status kargu-state--valid-statuses))
  (kargu-state--set :status new-status)
  (kargu-state-notify :status new-status detail)
  new-status)

(defun kargu-state-notify-tokens (&optional session)
  "Synchronize and notify token totals derived from SESSION's usage record."
  (let* ((resolved (kargu-session--resolve session))
         (tokens (kargu-state-tokens resolved)))
    (when (eq resolved (kargu-session-context))
      (kargu-state--sync-snapshot))
    (kargu-state-notify :prompt-tokens (plist-get tokens :prompt))
    (kargu-state-notify :completion-tokens (plist-get tokens :completion))
    (kargu-state-notify :total-tokens (plist-get tokens :total))
    tokens))

(defun kargu-state-record-tokens (prompt-tokens completion-tokens &optional session)
  "Accumulate PROMPT-TOKENS and COMPLETION-TOKENS into SESSION's usage record."
  (kargu-contract-assert (lambda (p) (or (null p) (natnump p))) prompt-tokens
                         "PROMPT-TOKENS must be a non-negative integer or nil: %S" prompt-tokens)
  (kargu-contract-assert (lambda (c) (or (null c) (natnump c))) completion-tokens
                         "COMPLETION-TOKENS must be a non-negative integer or nil: %S" completion-tokens)
  (let* ((resolved (kargu-session--resolve session))
         (usage (copy-sequence (kargu-session-usage-value resolved)))
         (p (or prompt-tokens 0))
         (c (or completion-tokens 0)))
    (setq usage (plist-put usage :tokens-in (+ (or (plist-get usage :tokens-in) 0) p)))
    (setq usage (plist-put usage :tokens-out (+ (or (plist-get usage :tokens-out) 0) c)))
    (setf (kargu-session-usage-value resolved) usage)
    (kargu-state-notify-tokens resolved)))

(defun kargu-state-reset ()
  "Reset state store back to clean initial state."
  (let ((fresh (kargu-state-init)))
    (kargu-state-notify :status :idle "reset")
    fresh))

(provide 'kargu/state/transitions)

;;; transitions.el ends here
