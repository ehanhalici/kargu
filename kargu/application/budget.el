;;; budget.el --- Run budget intent and native accounting projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Capture UI preferences and display authoritative Rust snapshots.  Request
;; admission, compaction limits and token accounting are exclusively native.
;; No local debit or estimated tool-text accounting is permitted here.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)

(declare-function kargu-bridge-budget-close "kargu/bridge/budget" (budget))

(defconst kargu-budget-default-max-requests 30
  "Default physical API attempts per root run.")
(defconst kargu-budget-default-max-compactions 1
  "Default logical compactions per root run.")

(cl-defstruct (kargu-run-budget (:constructor kargu-run-budget--create))
  "Captured preferences and detached native counters; never admission authority."
  (run-id nil :read-only t)
  (max-requests 30 :read-only t)
  (deadline nil :read-only t)
  (max-tokens nil :read-only t)
  (max-compactions 1 :read-only t)
  (requests-spent 0) (tokens-spent 0) (tokens-unknown-p nil)
  (compactions-spent 0) (status :ok) native)

(cl-defun kargu-budget-create (&key run-id
                                    (max-requests kargu-budget-default-max-requests)
                                    timeout max-tokens deadline
                                    (max-compactions kargu-budget-default-max-compactions))
  "Capture RUN-ID's UI budget intent; Rust admits every actual attempt.
MAX-REQUESTS and MAX-COMPACTIONS are bounded integer preferences.
MAX-TOKENS is an optional observed-usage ceiling, not a spend reservation.
TIMEOUT or absolute DEADLINE capture the original wall-clock expiry."
  (kargu-contract-assert (lambda (n) (and (integerp n) (<= 1 n 10000))) max-requests)
  (kargu-contract-assert (lambda (n) (and (integerp n) (<= 0 n 10000))) max-compactions)
  (when max-tokens
    (kargu-contract-assert (lambda (n) (and (integerp n) (> n 0))) max-tokens))
  (when timeout
    (kargu-contract-assert (lambda (n) (and (numberp n) (> n 0))) timeout))
  (when deadline (kargu-contract-assert #'numberp deadline))
  (kargu-run-budget--create
   :run-id run-id :max-requests max-requests :max-compactions max-compactions
   :max-tokens max-tokens :deadline (or deadline (and timeout (+ (float-time) timeout)))))

(defun kargu-budget-project (budget snapshot)
  "Install detached native SNAPSHOT counters in BUDGET without calculating usage."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (unless (and (hash-table-p snapshot)
               (cl-every (lambda (key) (natnump (gethash key snapshot)))
                         '("requests_spent" "compactions_spent" "tokens_spent" "outstanding"))
               (memq (gethash "tokens_unknown" snapshot :missing) '(t :json-false))
               (memq (gethash "sealed" snapshot :missing) '(t :json-false))
               (>= (gethash "requests_spent" snapshot) (kargu-run-budget-requests-spent budget))
               (>= (gethash "compactions_spent" snapshot) (kargu-run-budget-compactions-spent budget))
               (>= (gethash "tokens_spent" snapshot) (kargu-run-budget-tokens-spent budget))
               (or (not (kargu-run-budget-tokens-unknown-p budget))
                   (eq (gethash "tokens_unknown" snapshot) t)))
    (error "Invalid native budget projection"))
  (let* ((refusal (gethash "refusal" snapshot))
         (status (cond ((equal refusal "requests") :exhausted-requests)
                       ((equal refusal "compactions") :exhausted-compactions)
                       ((equal refusal "deadline") :exhausted-deadline)
                       ((equal refusal "tokens") :exhausted-tokens)
                       ((equal refusal "unknown_usage") :usage-unknown)
                       ((equal refusal "accounting") :accounting-failed)
                       ((or (null refusal) (eq refusal :json-null))
                        (if (eq (gethash "sealed" snapshot) t) :sealed :ok))
                       (t (error "Invalid native budget refusal")))))
    (setf (kargu-run-budget-requests-spent budget) (gethash "requests_spent" snapshot)
          (kargu-run-budget-compactions-spent budget) (gethash "compactions_spent" snapshot)
          (kargu-run-budget-tokens-spent budget) (gethash "tokens_spent" snapshot)
          (kargu-run-budget-tokens-unknown-p budget) (eq (gethash "tokens_unknown" snapshot) t))
    ;; A late observation cannot re-open a locally revoked delivery lifetime.
    (when (eq (kargu-run-budget-status budget) :ok)
      (setf (kargu-run-budget-status budget) status)))
  budget)

(defun kargu-budget-seal (budget)
  "Revoke BUDGET's editor ingress and request native drain on its existing lease."
  (kargu-contract-assert #'kargu-run-budget-p budget)
  (when (eq (kargu-run-budget-status budget) :ok)
    (setf (kargu-run-budget-status budget) :sealed))
  (when (fboundp 'kargu-bridge-budget-close) (kargu-bridge-budget-close budget))
  budget)

(defun kargu-budget-live-p (budget)
  "Return whether BUDGET's display lease is live; Rust remains the debit gate."
  (and (kargu-run-budget-p budget)
       (eq (kargu-run-budget-status budget) :ok)
       (or (null (kargu-run-budget-deadline budget))
           (< (float-time) (kargu-run-budget-deadline budget)))))

(defun kargu-budget-exhausted-p (budget)
  "Return non-nil when BUDGET's display lease is not live."
  (not (kargu-budget-live-p budget)))

(defun kargu-budget-remaining-requests (budget)
  "Display remaining attempts from BUDGET's last native projection."
  (max 0 (- (kargu-run-budget-max-requests budget) (kargu-run-budget-requests-spent budget))))

(defun kargu-budget-remaining-time (budget)
  "Display seconds before BUDGET's deadline, or nil when unlimited."
  (when-let* ((deadline (kargu-run-budget-deadline budget)))
    (max 0.0 (- deadline (float-time)))))

(defun kargu-budget-summary (budget)
  "Return BUDGET's detached display summary."
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
