;;; api.el --- Owned native retry observer delivery -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Present only the captured forward request's observer.  Native code owns
;; retries, timers and accounting; a stale/reentrant delivery never grants IO.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)

(defun kargu-bridge-api--owned-p (connection forward entry params)
  "Check ENTRY still owns FORWARD and observer PARAMS on CONNECTION."
  (and entry (eq (kargu-bridge-status connection) 'ready)
       (eq entry (gethash forward (kargu-bridge-connection-pending connection)))
       (functionp (kargu-bridge--pending-on-retry entry))
       (or (null (kargu-bridge--pending-owner entry))
           (buffer-live-p (kargu-bridge--pending-owner entry)))
       (equal (gethash "connection_epoch" params) (kargu-bridge-connection-epoch connection))
       (let ((actual (gethash "scope" params)) (captured (kargu-bridge--pending-api-scope entry)))
         (and (hash-table-p actual) (hash-table-p captured)
              (cl-every (lambda (key) (equal (gethash key actual) (gethash key captured)))
                        '("application_id" "session_id"))))))

(defun kargu-bridge-api-retry (connection id params)
  "Deliver native observer PARAMS for reverse ID on its exact CONNECTION.
ACK only if the same forward waiter remains live after the observer returns."
  (let* ((forward (and (hash-table-p params) (gethash "request_id" params)))
         (attempt (and (hash-table-p params) (gethash "attempt" params)))
         (entry (gethash forward (kargu-bridge-connection-pending connection))) accepted)
    (when (and (integerp attempt) (<= 1 attempt 10)
               (kargu-bridge-api--owned-p connection forward entry params)
               (> attempt (kargu-bridge--pending-retry-delivery entry)))
      (setf (kargu-bridge--pending-retry-delivery entry) attempt)
      (condition-case nil
          (progn
            (funcall (kargu-bridge--pending-on-retry entry) params)
            (setq accepted (kargu-bridge-api--owned-p connection forward entry params)))
        ((error quit) (kargu-bridge--cancel connection forward "consumer_failed"))))
    (kargu-bridge--send
     connection (kargu-bridge--object "jsonrpc" "2.0" "id" id
                                      "result" (kargu-bridge--object "accepted" (if accepted t :json-false))))))

(provide 'kargu/bridge/api)
;;; api.el ends here
