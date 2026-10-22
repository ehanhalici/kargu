;;; circuit.el --- Circuit breaker pattern for API requests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Circuit Breaker pattern with 3-state machine (:closed, :open, :half-open).
;; Prevents cascading failures and resource exhaustion when upstream providers
;; are down or experiencing outages.  Maintains provider-scoped isolation so
;; failures on one provider do not impact other providers (MOD-05, ARCH-15).
;; Public: `kargu-circuit-allow-request-p', `kargu-circuit-record-success',
;; `kargu-circuit-record-failure', `kargu-circuit-reset',
;; `kargu-circuit-status-string', `kargu-circuit-get'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract/assert)

(declare-function kargu--provider-name "kargu/config/key" ())

;;;; Configuration & state ------------------------------------------------

(defcustom kargu-circuit-failure-threshold 4
  "Number of consecutive failures required to trip the circuit open."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-circuit-cooldown-seconds 30.0
  "Seconds to stay in open state before attempting a canary probe."
  :type 'number
  :group 'kargu)

(cl-defstruct (kargu-circuit-breaker
               (:constructor kargu-circuit-breaker--create))
  "Scoped circuit breaker instance for a provider or connection endpoint."
  (key nil :read-only t)
  (state :closed)
  (failure-count 0)
  (probe-inflight nil)
  (last-failure-time 0.0)
  (threshold kargu-circuit-failure-threshold :read-only t)
  (cooldown kargu-circuit-cooldown-seconds :read-only t))

(defvar kargu-circuit--registry (make-hash-table :test #'equal)
  "Table of scoped circuit breakers keyed by provider or connection string.")

(defvar kargu-circuit--state :closed
  "Backward-compatibility mirror of the default circuit breaker state.")

(defvar kargu-circuit--failure-count 0
  "Backward-compatibility mirror of the default circuit failure count.")

(defvar kargu-circuit--probe-inflight nil
  "Backward-compatibility mirror of the default circuit probe-inflight.")

(defvar kargu-circuit--last-failure-time 0.0
  "Backward-compatibility mirror of the default circuit last failure time.")

;;;; Scope normalization & sync -------------------------------------------

(defun kargu-circuit--scope-key (&optional scope)
  "Normalize SCOPE to a canonical string key."
  (cond
   ((null scope) "default")
   ((symbolp scope) (downcase (symbol-name scope)))
   ((stringp scope) (downcase (string-trim scope)))
   (t (format "%s" scope))))

(defun kargu-circuit--sync-from-legacy (cb)
  "Import compatibility state only into the default breaker CB."
  (when (equal (kargu-circuit-breaker-key cb) "default")
    (setf (kargu-circuit-breaker-state cb) kargu-circuit--state
          (kargu-circuit-breaker-failure-count cb) kargu-circuit--failure-count
          (kargu-circuit-breaker-probe-inflight cb) kargu-circuit--probe-inflight
          (kargu-circuit-breaker-last-failure-time cb) kargu-circuit--last-failure-time)))

(defun kargu-circuit--sync-to-legacy (cb)
  "Publish compatibility state only from the default breaker CB."
  (when (equal (kargu-circuit-breaker-key cb) "default")
    (setq kargu-circuit--state (kargu-circuit-breaker-state cb)
          kargu-circuit--failure-count (kargu-circuit-breaker-failure-count cb)
          kargu-circuit--probe-inflight (kargu-circuit-breaker-probe-inflight cb)
          kargu-circuit--last-failure-time (kargu-circuit-breaker-last-failure-time cb))))

(defun kargu-circuit-get (&optional scope)
  "Return or create the `kargu-circuit-breaker' for SCOPE."
  (let* ((key (kargu-circuit--scope-key scope))
         (cb (or (gethash key kargu-circuit--registry)
                 (puthash key (kargu-circuit-breaker--create
                               :key key
                               :threshold kargu-circuit-failure-threshold
                               :cooldown kargu-circuit-cooldown-seconds)
                          kargu-circuit--registry))))
    (kargu-circuit--sync-from-legacy cb)
    cb))

;;;; State transitions & checks -------------------------------------------

(defun kargu-circuit--cooling-p (&optional scope)
  "Non-nil while breaker for SCOPE is :open and cooldown has not elapsed."
  (let* ((cb (kargu-circuit-get scope))
         (cooldown (or (and (boundp 'kargu-circuit-cooldown-seconds)
                            (numberp kargu-circuit-cooldown-seconds)
                            kargu-circuit-cooldown-seconds)
                       (kargu-circuit-breaker-cooldown cb)
                       30.0)))
    (and (eq (kargu-circuit-breaker-state cb) :open)
         (< (- (float-time) (kargu-circuit-breaker-last-failure-time cb))
            cooldown))))

(defun kargu-circuit-open-p (&optional scope)
  "Return non-nil when a request for SCOPE would be refused right now.
Unlike `kargu-circuit-allow-request-p' this changes nothing, so it may
be asked as often as needed."
  (let ((cb (kargu-circuit-get scope)))
    (or (kargu-circuit--cooling-p scope)
        (and (eq (kargu-circuit-breaker-state cb) :half-open)
             (kargu-circuit-breaker-probe-inflight cb)))))

(defun kargu-circuit-allow-request-p (&optional scope)
  "Return non-nil if a request for SCOPE may be sent, and claim the probe slot.
After the cooldown one request is let through as a probe (:half-open);
until its result is recorded every other request is refused.  Call this
only from the code that is about to send."
  (let ((cb (kargu-circuit-get scope)))
    (cond
     ((eq (kargu-circuit-breaker-state cb) :closed) t)
     ((kargu-circuit-open-p scope) nil)
     (t
      (when (eq (kargu-circuit-breaker-state cb) :open)
        (setf (kargu-circuit-breaker-state cb) :half-open)
        (kargu-log 'info "circuit breaker [%s]: cooldown elapsed; half-open canary probe"
                   (kargu-circuit-breaker-key cb)))
      (setf (kargu-circuit-breaker-probe-inflight cb) t)
      (kargu-circuit--sync-to-legacy cb)
      t))))

(defun kargu-circuit-release-probe (&optional scope)
  "Release an in-flight probe on breaker for SCOPE without declaring healthy."
  (let ((cb (kargu-circuit-get scope)))
    (setf (kargu-circuit-breaker-probe-inflight cb) nil)
    (kargu-circuit--sync-to-legacy cb)))

(defun kargu-circuit-record-success (&optional scope)
  "Record a successful request for SCOPE, closing its circuit breaker."
  (let ((cb (kargu-circuit-get scope)))
    (when (or (eq (kargu-circuit-breaker-state cb) :half-open)
              (eq (kargu-circuit-breaker-state cb) :open)
              (> (kargu-circuit-breaker-failure-count cb) 0))
      (kargu-log 'info "circuit breaker [%s]: request succeeded; resetting to :closed"
                 (kargu-circuit-breaker-key cb)))
    (setf (kargu-circuit-breaker-state cb) :closed
          (kargu-circuit-breaker-probe-inflight cb) nil
          (kargu-circuit-breaker-failure-count cb) 0)
    (kargu-circuit--sync-to-legacy cb)))

(defun kargu-circuit-record-failure (&optional reason scope)
  "Record a failed request for SCOPE with optional REASON string.
If failures reach threshold, trips circuit to :open."
  (kargu-contract-assert (lambda (r) (or (null r) (stringp r))) reason
                         "REASON must be a string or nil: %S" reason)
  (let* ((cb (kargu-circuit-get scope))
         (threshold (or (and (boundp 'kargu-circuit-failure-threshold)
                             (integerp kargu-circuit-failure-threshold)
                             kargu-circuit-failure-threshold)
                        (kargu-circuit-breaker-threshold cb)
                        4))
         (cooldown (or (and (boundp 'kargu-circuit-cooldown-seconds)
                            (numberp kargu-circuit-cooldown-seconds)
                            kargu-circuit-cooldown-seconds)
                       (kargu-circuit-breaker-cooldown cb)
                       30.0)))
    (setf (kargu-circuit-breaker-last-failure-time cb) (float-time)
          (kargu-circuit-breaker-probe-inflight cb) nil)
    (setf (kargu-circuit-breaker-failure-count cb) (1+ (kargu-circuit-breaker-failure-count cb)))
    (cond
     ((eq (kargu-circuit-breaker-state cb) :half-open)
      (setf (kargu-circuit-breaker-state cb) :open)
      (kargu-log 'warn "circuit breaker [%s]: half-open canary probe failed (%s); tripped back to :open"
                 (kargu-circuit-breaker-key cb)
                 (or reason "unknown error")))
     ((>= (kargu-circuit-breaker-failure-count cb) threshold)
      (setf (kargu-circuit-breaker-state cb) :open)
      (kargu-log 'warn "circuit breaker [%s]: %d consecutive failures reached (%s); circuit OPEN for %.1fs"
                 (kargu-circuit-breaker-key cb)
                 (kargu-circuit-breaker-failure-count cb)
                 (or reason "unknown error")
                 cooldown))
     (t
      (kargu-log 'debug "circuit breaker [%s]: failure %d/%d (%s)"
                 (kargu-circuit-breaker-key cb)
                 (kargu-circuit-breaker-failure-count cb)
                 (kargu-circuit-breaker-threshold cb)
                 (or reason "error"))))
    (kargu-circuit--sync-to-legacy cb)))

(defun kargu-circuit-reset (&optional scope)
  "Reset circuit breaker for SCOPE, or all breakers if SCOPE is `all'."
  (interactive)
  (if (eq scope 'all)
      (progn
        (clrhash kargu-circuit--registry)
        (setq kargu-circuit--state :closed
              kargu-circuit--probe-inflight nil
              kargu-circuit--failure-count 0
              kargu-circuit--last-failure-time 0.0)
        (kargu-log 'info "circuit breaker: all scoped breakers reset to :closed"))
    (let ((cb (kargu-circuit-get scope)))
      (setf (kargu-circuit-breaker-state cb) :closed
            (kargu-circuit-breaker-probe-inflight cb) nil
            (kargu-circuit-breaker-failure-count cb) 0
            (kargu-circuit-breaker-last-failure-time cb) 0.0)
      (kargu-circuit--sync-to-legacy cb)
      (kargu-log 'info "circuit breaker [%s]: manually reset to :closed"
                 (kargu-circuit-breaker-key cb))))
  (when (called-interactively-p 'any)
    (message "kargu: circuit breaker reset to closed")))

(defun kargu-circuit-status-string (&optional scope)
  "Return human-readable circuit breaker status for SCOPE."
  (let ((cb (kargu-circuit-get scope)))
    (pcase (kargu-circuit-breaker-state cb)
      (:closed "closed (healthy)")
      (:half-open "half-open (probing)")
      (:open
       (let ((remaining (max 0.0 (- (+ (kargu-circuit-breaker-last-failure-time cb)
                                       (kargu-circuit-breaker-cooldown cb))
                                    (float-time)))))
         (format "OPEN (cooldown: %.0fs remaining)" remaining)))
      (_ "unknown"))))

(provide 'kargu/api/circuit)

;;; circuit.el ends here
