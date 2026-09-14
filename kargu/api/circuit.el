;;; kargu/api/circuit.el --- Circuit breaker pattern for API requests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Circuit Breaker pattern with 3-state machine (:closed, :open, :half-open).
;; Prevents cascading failures and resource exhaustion when upstream providers
;; are down or experiencing outages.
;; Public: `kargu-circuit-allow-request-p`, `kargu-circuit-record-success`,
;; `kargu-circuit-record-failure`, `kargu-circuit-reset`,
;; `kargu-circuit-status-string`.

;;; Code:

(require 'cl-lib)
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

(require 'kargu/core)
(require 'kargu/contract/assert)

;;;; Configuration & state ------------------------------------------------

(defcustom kargu-circuit-failure-threshold 4
  "Number of consecutive failures required to trip the circuit open."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-circuit-cooldown-seconds 30.0
  "Seconds to stay in open state before attempting a canary probe."
  :type 'number
  :group 'kargu)

(defvar kargu-circuit--state :closed
  "Current state: :closed (normal), :open (failing fast), :half-open (probing).")

(defvar kargu-circuit--failure-count 0
  "Count of consecutive failures in closed or half-open state.")

(defvar kargu-circuit--last-failure-time 0.0
  "Float timestamp of the most recent failure.")

;;;; State transitions & checks -------------------------------------------

(defun kargu-circuit-allow-request-p ()
  "Return non-nil if a request is allowed through the circuit breaker.
If :open and the cooldown period has elapsed, transitions to :half-open."
  (cond
   ((eq kargu-circuit--state :closed) t)
   ((eq kargu-circuit--state :half-open) t)
   ((eq kargu-circuit--state :open)
    (let ((elapsed (- (float-time) kargu-circuit--last-failure-time)))
      (if (>= elapsed kargu-circuit-cooldown-seconds)
          (progn
            (setq kargu-circuit--state :half-open)
            (kargu-log 'info "circuit breaker: cooldown elapsed; half-open canary probe")
            t)
        nil)))
   (t t)))

(defun kargu-circuit-record-success ()
  "Record a successful request, resetting the failure count and closing circuit."
  (when (or (eq kargu-circuit--state :half-open)
            (eq kargu-circuit--state :open)
            (> kargu-circuit--failure-count 0))
    (kargu-log 'info "circuit breaker: request succeeded; resetting to :closed"))
  (setq kargu-circuit--state :closed
        kargu-circuit--failure-count 0))

(defun kargu-circuit-record-failure (&optional reason)
  "Record a failed request with optional REASON string.
If failures reach `kargu-circuit-failure-threshold', trips circuit to :open."
  (kargu-contract-assert (lambda (r) (or (null r) (stringp r))) reason
                         "REASON must be a string or nil: %S" reason)
  (setq kargu-circuit--last-failure-time (float-time))
  (setq kargu-circuit--failure-count (1+ kargu-circuit--failure-count))
  (cond
   ((eq kargu-circuit--state :half-open)
    (setq kargu-circuit--state :open)
    (kargu-log 'warn "circuit breaker: half-open canary probe failed (%s); tripped back to :open"
               (or reason "unknown error")))
   ((>= kargu-circuit--failure-count kargu-circuit-failure-threshold)
    (setq kargu-circuit--state :open)
    (kargu-log 'warn "circuit breaker: %d consecutive failures reached (%s); circuit OPEN for %.1fs"
               kargu-circuit--failure-count
               (or reason "unknown error")
               kargu-circuit-cooldown-seconds))
   (t
    (kargu-log 'debug "circuit breaker: failure %d/%d (%s)"
               kargu-circuit--failure-count
               kargu-circuit-failure-threshold
               (or reason "error")))))

(defun kargu-circuit-reset ()
  "Manually reset the circuit breaker to :closed state."
  (interactive)
  (setq kargu-circuit--state :closed
        kargu-circuit--failure-count 0
        kargu-circuit--last-failure-time 0.0)
  (kargu-log 'info "circuit breaker: manually reset to :closed")
  (when (called-interactively-p 'any)
    (message "kargu: circuit breaker reset to closed")))

(defun kargu-circuit-status-string ()
  "Return human-readable circuit breaker status."
  (pcase kargu-circuit--state
    (:closed "closed (healthy)")
    (:half-open "half-open (probing)")
    (:open
     (let ((remaining (max 0.0 (- (+ kargu-circuit--last-failure-time
                                     kargu-circuit-cooldown-seconds)
                                  (float-time)))))
       (format "OPEN (cooldown: %.0fs remaining)" remaining)))
    (_ "unknown")))

(provide 'kargu/api/circuit)

;;; kargu/api/circuit.el ends here
