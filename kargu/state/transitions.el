;;; kargu/state/transitions.el --- Validated state transitions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; State transition functions with precondition validation and event notification.
;; Ensures invalid states cannot be entered.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

(require 'kargu/contract/types)
(require 'kargu/contract/assert)
(require 'kargu/state/store)
(require 'kargu/state/selectors)
(require 'kargu/state/hooks)

(defconst kargu-state--valid-statuses
  '(:idle :requesting :waiting-model :executing-tools :verifying :compacting :pause :done :limit :stopped :error)
  "List of valid lifecycle statuses for the Kargu state machine.")

(defvar kargu-active-mode)

(defun kargu-state-set-mode (mode)
  "Set the active operating mode to MODE (`ask', `plan', `debug', or `agent').
Validates MODE and ensures an agent run is not currently active."
  (kargu-contract-assert #'kargu-contract-mode-p mode
                         "Invalid kargu mode: %S (expected one of %s)"
                         mode kargu-all-modes)
  (when (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (user-error "kargu: cannot change mode while an agent run is in progress (M-x kargu-loop-stop)"))
  (kargu-state-set :mode mode)
  (setq kargu-active-mode mode)
  (kargu-state-notify :mode mode)
  mode)

(defun kargu-state-set-provider (provider)
  "Set the active PROVIDER symbol."
  (kargu-contract-assert #'symbolp provider "PROVIDER must be a symbol: %S" provider)
  (kargu-state-set :provider provider)
  (kargu-state-notify :provider provider)
  provider)

(defun kargu-state-set-model (model)
  "Set the active MODEL string identifier."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p model
                         "MODEL must be a non-empty string: %S" model)
  (kargu-state-set :model model)
  (kargu-state-notify :model model)
  model)

(defun kargu-state-set-reasoning-effort (effort)
  "Set the active reasoning EFFORT (`low', `medium', `high', or nil)."
  (unless (memq effort '(nil low medium high))
    (error "Invalid reasoning effort: %S (expected low, medium, high, or nil)" effort))
  (kargu-state-set :reasoning-effort effort)
  (kargu-state-notify :reasoning-effort effort)
  effort)

(defun kargu-state-set-thinking-budget (budget)
  "Set the active thinking BUDGET integer or nil."
  (unless (or (null budget) (natnump budget))
    (error "Invalid thinking budget: %S (expected integer or nil)" budget))
  (kargu-state-set :thinking-budget budget)
  budget)

(defun kargu-state-transition-status (new-status &optional detail)
  "Transition the state machine to NEW-STATUS with optional DETAIL.
Validates that NEW-STATUS is a known status and updates `:busy'."
  (unless (memq new-status kargu-state--valid-statuses)
    (error "Invalid lifecycle status: %S (expected one of %s)"
           new-status kargu-state--valid-statuses))
  (kargu-state-set :status new-status)
  (let ((busy (if (memq new-status '(:idle :stopped :error :done :limit :pause)) nil t)))
    (kargu-state-set :busy busy))
  (kargu-state-notify :status new-status detail)
  new-status)

(defun kargu-state-set-loop-run (run)
  "Set the active loop RUN plist or nil."
  (kargu-state-set :loop-run run)
  run)

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
    (kargu-state-set :prompt-tokens (+ cur-p p))
    (kargu-state-set :completion-tokens (+ cur-c c))
    (kargu-state-set :total-tokens (+ cur-tot tot))
    (kargu-state-tokens)))

(defun kargu-state-set-context-buffer (buf)
  "Set the active context buffer to BUF."
  (kargu-contract-assert (lambda (b) (or (null b) (bufferp b) (stringp b))) buf
                         "BUF must be a buffer, buffer name or nil: %S" buf)
  (kargu-state-set :context-buffer buf)
  buf)

(defun kargu-state-reset ()
  "Reset state store back to clean initial state."
  (let ((fresh (kargu-state-init)))
    (when (boundp 'kargu-active-mode)
      (setq kargu-active-mode 'ask))
    (kargu-state-notify :status :idle "reset")
    fresh))

(provide 'kargu/state/transitions)

;;; kargu/state/transitions.el ends here
