;;; credential.el --- Native run credential capture adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Answer one Rust `editor/credential' request for a claimed native run.  Rust
;; decides that a credential is needed, its provider and host, and the deadline;
;; this adapter only runs the editor capture and reports its actual completion.
;; Cancellation revokes key delivery but the receipt still waits for the worker
;; to quiesce, and a changed epoch or owner never receives a key.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/async)
(require 'kargu/config/worker)

(defun kargu-bridge-credential--valid-p (connection id params)
  "Check that ID/PARAMS name a live forward run request on CONNECTION."
  (let ((forward (and (hash-table-p params) (gethash "request_id" params))))
    (and (kargu-bridge--valid-id-p id)
         (not (gethash id (kargu-bridge-connection-reverse-cleanups connection)))
         (gethash forward (kargu-bridge-connection-pending connection))
         (equal (gethash "connection_epoch" params) (kargu-bridge-connection-epoch connection))
         (hash-table-p (gethash "scope" params))
         (stringp (gethash "capture_id" params))
         (stringp (gethash "provider" params)) (not (string-empty-p (gethash "provider" params)))
         (stringp (gethash "host" params)) (not (string-empty-p (gethash "host" params)))
         (natnump (gethash "timeout_ms" params)) (> (gethash "timeout_ms" params) 0))))

(defun kargu-bridge-credential--reply (connection id params outcome key)
  "Send CONNECTION's quiescent receipt for ID/PARAMS with OUTCOME and KEY."
  (when (eq (kargu-bridge-status connection) 'ready)
    (kargu-bridge--send
     connection
     (kargu-bridge--object
      "jsonrpc" "2.0" "id" id
      "result" (kargu-bridge--object
                "scope" (gethash "scope" params) "capture_id" (gethash "capture_id" params)
                "quiescent" t "outcome" outcome "key" (or key :json-null))))))

(defun kargu-bridge-credential-request (connection id params)
  "Capture the credential Rust requested in ID/PARAMS on CONNECTION.
An unowned or malformed request is refused without starting work."
  (if (not (kargu-bridge-credential--valid-p connection id params))
      (kargu-bridge--send
       connection (kargu-bridge--object
                   "jsonrpc" "2.0" "id" id
                   "error" (kargu-bridge--object "code" -32602 "message" "Invalid credential request")))
    (let* ((epoch (kargu-bridge-connection-epoch connection))
           (forward (gethash "request_id" params))
           (table (kargu-bridge-connection-reverse-cleanups connection))
           ;; Rust owns the deadline; the task mirrors it only to bound the worker.
           (task (kargu-async-start #'ignore :owner nil :parent nil
                                    :timeout (/ (gethash "timeout_ms" params) 1000.0))))
      (puthash id (cons forward (lambda () (kargu-async-cancel task))) table)
      (kargu-config-worker-capture
       (gethash "provider" params) (gethash "host" params) task
       (lambda (result)
         (remhash id table)
         (let* ((current (and (equal epoch (kargu-bridge-connection-epoch connection))
                              (gethash forward (kargu-bridge-connection-pending connection))))
                (key (and current (kargu-ok-p result) (kargu-result-value result))))
           (kargu-bridge-credential--reply
            connection id params
            (cond (key "resolved")
                  ((or (not current) (eq (kargu-result-err-code result) :cancelled)) "cancelled")
                  (t "unavailable"))
            key)))))))

(provide 'kargu/bridge/credential)
;;; credential.el ends here
