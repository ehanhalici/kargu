;;; failure.el --- Typed native API failure projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Translate a closed native vocabulary into editor Result errors.  No status,
;; curl or prose classification, replay decision or circuit mutation lives here.

;;; Code:

(require 'kargu/contract/result)

(defconst kargu-api-failure--categories
  '(("invalid-request" . :invalid-request) ("resource-limit" . :resource-limit)
    ("cancelled" . :cancelled) ("connection-failed" . :connection-failed)
    ("timeout" . :timeout) ("budget-exhausted" . :budget-exhausted)
    ("retry-unavailable" . :retry-unavailable) ("redirect-refused" . :redirect-refused)
    ("bad-request" . :bad-request) ("authentication-failed" . :authentication-failed)
    ("permission-denied" . :permission-denied) ("not-found" . :not-found)
    ("rate-limit-exceeded" . :rate-limit-exceeded) ("server-error" . :server-error)
    ("bad-gateway" . :bad-gateway) ("gateway-timeout" . :gateway-timeout)
    ("overloaded" . :overloaded) ("http-error" . :http-error)
    ("context-overflow" . :context-overflow) ("protocol-error" . :protocol-error)
    ("incomplete-stream" . :incomplete-stream))
  "Wire labels, not execution rights.  Never intern untrusted category strings.")

(defun kargu-api-failure-result (snapshot &optional partial)
  "Project native SNAPSHOT and PARTIAL into a detached terminal Result error."
  (let* ((category (and (hash-table-p snapshot)
                        (cdr (assoc (gethash "category" snapshot)
                                    kargu-api-failure--categories))))
         (code (and category (gethash "code" snapshot)))
         (message (and category (gethash "message" snapshot)))
         (status (and category (gethash "status" snapshot)))
         (reason (and category (gethash "reason" snapshot))))
    (if (not (and category (stringp code) (<= (length code) 80)
                  (stringp message) (<= (length message) 1024)
                  (or (null status) (and (integerp status) (<= 100 status 599)))
                  (or (null reason) (and (stringp reason) (<= (length reason) 80)))))
        (kargu-err "Invalid native API failure" :protocol-error)
      (when (eq (gethash "retry_after_exceeded" snapshot) t)
        (setq message "Provider Retry-After exceeds supported wait; automatic retry refused"))
      (kargu-err (if status (format "HTTP %d: %s" status message) (copy-sequence message))
                 category
                 (list :native-code (copy-sequence code) :status status
                       :reason (and reason (copy-sequence reason)) :partial partial
                       :retry-after-exceeded (eq (gethash "retry_after_exceeded" snapshot) t))))))

(defun kargu-api-failure-ipc-result (failure)
  "Project local IPC/admission FAILURE without guessing upstream health."
  (let* ((data (and (hash-table-p failure) (gethash "data" failure)))
         (status (and (hash-table-p data) (gethash "status" data)))
         (message (and (hash-table-p failure) (gethash "message" failure)))
         (category (or (cdr (assoc status '(("budget_exhausted" . :budget-exhausted)
                                            ("cancelled" . :cancelled)
                                            ("invalid_params" . :invalid-request)
                                            ("invalid_request" . :invalid-request)
                                            ("circuit_open" . :circuit-open))))
                       :service-unavailable)))
    (kargu-err (if (and (stringp message) (<= (length message) 1024))
                   (copy-sequence message) "Rust API service unavailable")
               category (list :native-code (and (stringp status) (copy-sequence status))))))

(provide 'kargu/api/failure)
;;; failure.el ends here
