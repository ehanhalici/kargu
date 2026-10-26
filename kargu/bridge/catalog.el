;;; catalog.el --- Bounded native catalog target projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This readonly port captures one connection epoch.  It does not acquire an
;; application lease, choose endpoints or touch credentials.  The returned
;; connection must also own the later GET; lost epochs are never replayed.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)
(require 'kargu/providers/projection)

(defconst kargu-bridge-catalog-timeout 5.0
  "Seconds allowed for startup and one readonly native target projection.")

(defun kargu-bridge-catalog--ready (task arguments connection failure)
  "Project ARGUMENTS for TASK on CONNECTION, or deliver startup FAILURE."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((not (member "provider_catalog_target" (append (kargu-bridge-connection-capabilities connection) nil)))
    (kargu-async-finish task nil (kargu-bridge--fault "unsupported_catalog_target")))
   (t
    (let ((id (kargu-bridge-call
               connection "provider/catalogTarget"
               (kargu-bridge--object "connection_epoch" (kargu-bridge-connection-epoch connection)
                                     "arguments" arguments)
               (kargu-async-wrap task (lambda (result error-data) (kargu-async-finish task result error-data)))
               :owner (kargu-async-task-buffer task)
               :timeout (max 0.001 (- (kargu-async-task-deadline task) (float-time))))))
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))

(cl-defun kargu-bridge-catalog-target (arguments callback &key parent application)
  "Project captured ARGUMENTS into CALLBACK under PARENT and APPLICATION.
CALLBACK receives (DTO FAILURE CONNECTION).  No HTTP or credential IO occurs."
  (kargu-contract-assert #'hash-table-p arguments)
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert #'kargu-application-p application)
  (let* ((arguments (kargu-providers-wire-object arguments))
         connection
         (task (kargu-async-start
                (kargu-application-wrap application
                                        (lambda (result failure) (funcall callback result failure connection)))
                :parent parent :owner nil :timeout kargu-bridge-catalog-timeout))
         (binding (gethash :native-core (kargu-application-services application)))
         (ready (kargu-async-wrap
                 task (lambda (value failure)
                        (setq connection value)
                        (kargu-bridge-catalog--ready task arguments value failure)))))
    (when (kargu-async-pending-p task)
      (if binding
          (let ((captured (kargu-bridge-application-connection binding)))
            (funcall ready captured
                     (unless (kargu-bridge-application-current-p application captured)
                       (kargu-bridge--fault "owner_closed"))))
        (kargu-async-add-cleanup task (kargu-bridge-ensure ready))))
    task))

(provide 'kargu/bridge/catalog)
;;; catalog.el ends here
