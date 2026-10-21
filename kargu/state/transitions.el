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
  '(:idle :requesting :waiting-model :executing-tools :verifying :compacting :pause :done :limit :stopped :error)
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
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "Kargu: cannot change mode while an agent run is in progress (M-x kargu-loop-stop)"))
  (let ((origin (current-buffer)) (owner (kargu-session-context))
        (previous (kargu-session-mode-revision (kargu-session-context)))
        (intent (kargu-session-mode-request (kargu-session-context))))
    (run-hook-with-args 'kargu-state-before-mode-change-hook mode)
    (unless (and (eq origin (current-buffer))
                 (eq owner (kargu-session-context origin))
                 (= previous (kargu-session-mode-revision owner))
                 (eq intent (kargu-session-mode-request owner))
                 (not (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p)))
                 (not (and (fboundp 'kargu-busy-p) (kargu-busy-p))))
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
Validates that NEW-STATUS is a known status and updates `:busy'."
  (unless (memq new-status kargu-state--valid-statuses)
    (error "Invalid lifecycle status: %S (expected one of %s)"
           new-status kargu-state--valid-statuses))
  (kargu-state--set :status new-status)
  (let ((busy (if (memq new-status '(:idle :stopped :error :done :limit :pause)) nil t)))
    (kargu-state--set :busy busy))
  (kargu-state-notify :status new-status detail)
  new-status)

(defun kargu-state-record-tokens (prompt-tokens completion-tokens)
  "Accumulate PROMPT-TOKENS and COMPLETION-TOKENS into cumulative usage."
  (kargu-contract-assert (lambda (p) (or (null p) (natnump p))) prompt-tokens
                         "PROMPT-TOKENS must be a non-negative integer or nil: %S" prompt-tokens)
  (kargu-contract-assert (lambda (c) (or (null c) (natnump c))) completion-tokens
                         "COMPLETION-TOKENS must be a non-negative integer or nil: %S" completion-tokens)
  (let* ((p (or prompt-tokens 0))
         (c (or completion-tokens 0))
         (tot (+ p c))
         (cur-p (or (kargu-state-get :prompt-tokens) 0))
         (cur-c (or (kargu-state-get :completion-tokens) 0))
         (cur-tot (or (kargu-state-get :total-tokens) 0)))
    (kargu-state--set :prompt-tokens (+ cur-p p))
    (kargu-state--set :completion-tokens (+ cur-c c))
    (kargu-state--set :total-tokens (+ cur-tot tot))
    (dolist (key '(:prompt-tokens :completion-tokens :total-tokens))
      (kargu-state-notify key (kargu-state-get key)))
    (kargu-state-tokens)))

(defun kargu-state-reset ()
  "Reset state store back to clean initial state."
  (let ((fresh (kargu-state-init)))
    (kargu-state-notify :status :idle "reset")
    fresh))

(provide 'kargu/state/transitions)

;;; transitions.el ends here
