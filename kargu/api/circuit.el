;;; circuit.el --- Native circuit preferences and display facade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; No editor admission, failure accounting, probe grants or cooldown clock.
;; Native views are display-only; explicit reset uses the captured live lease.

;;; Code:

(require 'kargu/core)
(require 'kargu/bridge/circuit)

(declare-function kargu--provider-name "kargu/config/key" ())

(defcustom kargu-circuit-failure-threshold 4
  "Consecutive native upstream failures required to open the circuit (1–1000)."
  :type 'natnum :group 'kargu)

(defcustom kargu-circuit-cooldown-seconds 30
  "Native circuit cooldown in seconds, greater than zero and at most one day."
  :type 'number :group 'kargu)

(defun kargu-circuit-preferences ()
  "Capture native circuit configuration, leaving validation to Rust."
  `(("failure_threshold" . ,kargu-circuit-failure-threshold)
    ("cooldown_ms" . ,(ceiling (* kargu-circuit-cooldown-seconds 1000)))))

(defun kargu-circuit-get (&optional provider)
  "Return a detached native PROVIDER view, or nil when no view is available."
  (kargu-bridge-circuit-view (kargu-application-context) (or provider (kargu--provider-name))))

(defun kargu-circuit-reset (&optional provider callback)
  "Explicitly reset native PROVIDER; `all' resets this application's circuits.
CALLBACK receives result/error after native acknowledgement.  Never reconnect."
  (interactive)
  (let ((interactive-p (called-interactively-p 'any)))
    (kargu-bridge-circuit-reset
     (kargu-application-context) (unless (eq provider 'all) (or provider (kargu--provider-name)))
     (or callback (lambda (_result failure)
                    (when interactive-p
                      (message "kargu: circuit reset %s" (if failure "unavailable" "acknowledged"))))))))

(defun kargu-circuit-status-string (&optional provider)
  "Return last observed native PROVIDER state, not an admission prediction."
  (if-let* ((view (kargu-circuit-get provider)))
      (format "%s (native observation; %d failures)" (gethash "state" view) (gethash "failures" view))
    "unavailable (no native observation)"))

(provide 'kargu/api/circuit)
;;; circuit.el ends here
