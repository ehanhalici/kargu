;;; budget.el --- Unified run budget accounting and debit gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Unified accounting record for requests, deadlines, and tokens per run.
;; Guarantees a single debit gate for normal requests, retries, healing,
;; and context compaction (ARCH-01, DEEP-09, Contract 6).
;; Unknown usage is explicitly tracked and never coerced to zero.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)
(require 'kargu/contract/result)

(defconst kargu-budget-default-max-requests 30
  "Default maximum number of requests allowed per agent run.")

(defconst kargu-budget-default-max-compactions 1
  "Default maximum number of context compaction turns allowed per agent run.")

(cl-defstruct (kargu-run-budget
               (:constructor kargu-run-budget--create))
  "Unified accounting record for requests, deadlines, and tokens per run."
  (run-id nil :read-only t)
  (max-requests 30 :read-only t)
  (requests-spent 0)
  (deadline nil :read-only t)
  (max-tokens nil :read-only t)
  (tokens-spent 0)
  (tokens-unknown-p nil)
  (max-compactions 1 :read-only t)
  (compactions-spent 0)
  (status :ok))

(cl-defun kargu-budget-create (&key run-id (max-requests kargu-budget-default-max-requests)
                                    timeout max-tokens
                                    (max-compactions kargu-budget-default-max-compactions)
                                    deadline)
  "Create a fresh `kargu-run-budget' record for RUN-ID.
MAX-REQUESTS bounds total HTTP turns and retries.
TIMEOUT sets a deadline relative to current time in seconds.
DEADLINE directly sets an absolute deadline timestamp (float-time).
MAX-TOKENS optionally caps cumulative tokens.
MAX-COMPACTIONS caps context compaction turns (defaults to 1)."
  (when max-requests
    (kargu-contract-assert (lambda (n) (and (integerp n) (> n 0)))
                           max-requests "MAX-REQUESTS must be a positive integer: %S" max-requests))
  (when max-tokens
    (kargu-contract-assert (lambda (n) (and (integerp n) (> n 0)))
                           max-tokens "MAX-TOKENS must be a positive integer: %S" max-tokens))
  (when max-compactions
    (kargu-contract-assert (lambda (n) (and (integerp n) (>= n 0)))
                           max-compactions "MAX-COMPACTIONS must be a non-negative integer: %S" max-compactions))
  (when timeout
    (kargu-contract-assert (lambda (n) (and (numberp n) (> n 0)))
                           timeout "TIMEOUT must be a positive number: %S" timeout))
  (when deadline
    (kargu-contract-assert #'numberp deadline
                           "DEADLINE must be a number: %S" deadline))
  (let ((effective-deadline (or deadline
                                (when (and timeout (> timeout 0))
                                  (+ (float-time) timeout)))))
    (kargu-run-budget--create
     :run-id run-id
     :max-requests (or max-requests kargu-budget-default-max-requests)
     :requests-spent 0
     :deadline effective-deadline
     :max-tokens max-tokens
     :tokens-spent 0
     :tokens-unknown-p nil
     :max-compactions (or max-compactions kargu-budget-default-max-compactions)
     :compactions-spent 0
     :status :ok)))

(defun kargu-budget--refusal (budget type requests tokens)
  "Classify BUDGET refusal for TYPE, REQUESTS and optional TOKENS without debit."
  (cond
   ((not (eq (kargu-run-budget-status budget) :ok)) (kargu-run-budget-status budget))
   ((and (kargu-run-budget-deadline budget)
         (>= (float-time) (kargu-run-budget-deadline budget))) :exhausted-deadline)
   ((and (eq type :compaction-turn)
         (>= (kargu-run-budget-compactions-spent budget)
             (kargu-run-budget-max-compactions budget))) :exhausted-compactions)
   ((> (+ requests (kargu-run-budget-requests-spent budget))
       (kargu-run-budget-max-requests budget)) :exhausted-requests)
   ((and (kargu-run-budget-max-tokens budget)
         (> (+ (or tokens 0) (kargu-run-budget-tokens-spent budget))
            (kargu-run-budget-max-tokens budget))) :exhausted-tokens)))

(cl-defun kargu-budget-debit (budget debit-type &key (requests 1) tokens)
  "Atomically debit REQUESTS and optional TOKENS from BUDGET for DEBIT-TYPE.
Normal, retry, compaction, healing and continuation requests share this gate."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (kargu-contract-assert
   (lambda (type) (memq type '(:normal-request :retry-attempt :compaction-turn
                              :healing-turn :continuation)))
   debit-type)
  (kargu-contract-assert (lambda (n) (and (integerp n) (> n 0))) requests)
  (when tokens (kargu-contract-assert #'natnump tokens))
  (let ((refusal (kargu-budget--refusal budget debit-type requests tokens)))
    (if refusal
        (progn
          (setf (kargu-run-budget-status budget) refusal)
          (kargu-err "Run budget exhausted" :budget-exhausted
                     (list :reason refusal :run-id (kargu-run-budget-run-id budget))))
      (cl-incf (kargu-run-budget-requests-spent budget) requests)
      (when tokens (cl-incf (kargu-run-budget-tokens-spent budget) tokens))
      (when (eq debit-type :compaction-turn)
        (cl-incf (kargu-run-budget-compactions-spent budget)))
      (kargu-ok budget))))

(defun kargu-budget-record-tokens (budget prompt-tokens completion-tokens)
  "Record PROMPT-TOKENS and COMPLETION-TOKENS into BUDGET.
If token counts are nil, sets `tokens-unknown-p' to t without coercing to zero.
Returns BUDGET."
  (kargu-contract-assert #'kargu-run-budget-p budget
                         "BUDGET must be a kargu-run-budget: %S" budget)
  (when prompt-tokens
    (kargu-contract-assert (lambda (n) (and (integerp n) (>= n 0))) prompt-tokens
                           "PROMPT-TOKENS must be a non-negative integer: %S" prompt-tokens))
  (when completion-tokens
    (kargu-contract-assert (lambda (n) (and (integerp n) (>= n 0))) completion-tokens
                           "COMPLETION-TOKENS must be a non-negative integer: %S" completion-tokens))
  (if (and (null prompt-tokens) (null completion-tokens))
      (setf (kargu-run-budget-tokens-unknown-p budget) t)
    (let ((p (or prompt-tokens 0))
          (c (or completion-tokens 0)))
      (when (or (null prompt-tokens) (null completion-tokens))
        (setf (kargu-run-budget-tokens-unknown-p budget) t))
      (cl-incf (kargu-run-budget-tokens-spent budget) (+ p c))
      (when (and (kargu-run-budget-max-tokens budget)
                 (> (kargu-run-budget-tokens-spent budget)
                    (kargu-run-budget-max-tokens budget)))
        (setf (kargu-run-budget-status budget) :exhausted-tokens))))
  budget)

(defun kargu-budget-seal (budget)
  "Seal BUDGET against any further debits.
Returns BUDGET."
  (kargu-contract-assert #'kargu-run-budget-p budget
                         "BUDGET must be a kargu-run-budget: %S" budget)
  (unless (memq (kargu-run-budget-status budget)
                '(:exhausted-requests :exhausted-deadline :exhausted-tokens :exhausted-compactions))
    (setf (kargu-run-budget-status budget) :sealed))
  budget)

(defun kargu-budget-live-p (budget)
  "Return non-nil if BUDGET can accept debits."
  (and (kargu-run-budget-p budget)
       (eq (kargu-run-budget-status budget) :ok)
       (let ((deadline (kargu-run-budget-deadline budget)))
         (or (null deadline) (<= (float-time) deadline)))))

(defun kargu-budget-exhausted-p (budget)
  "Return non-nil if BUDGET is exhausted, expired, or sealed."
  (not (kargu-budget-live-p budget)))

(defun kargu-budget-remaining-requests (budget)
  "Return remaining requests allowed on BUDGET."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (max 0 (- (kargu-run-budget-max-requests budget)
            (kargu-run-budget-requests-spent budget))))

(defun kargu-budget-remaining-time (budget)
  "Return remaining seconds before deadline on BUDGET, or nil if no deadline."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (when-let* ((deadline (kargu-run-budget-deadline budget)))
    (max 0.0 (- deadline (float-time)))))

(defun kargu-budget-summary (budget)
  "Return an immutable summary plist of BUDGET."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (list :run-id (kargu-run-budget-run-id budget)
        :status (kargu-run-budget-status budget)
        :requests-spent (kargu-run-budget-requests-spent budget)
        :max-requests (kargu-run-budget-max-requests budget)
        :tokens-spent (kargu-run-budget-tokens-spent budget)
        :max-tokens (kargu-run-budget-max-tokens budget)
        :tokens-unknown-p (kargu-run-budget-tokens-unknown-p budget)
        :compactions-spent (kargu-run-budget-compactions-spent budget)
        :max-compactions (kargu-run-budget-max-compactions budget)
        :live-p (kargu-budget-live-p budget)))

(provide 'kargu/application/budget)

;;; budget.el ends here
