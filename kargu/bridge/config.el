;;; config.el --- Owned readonly native configuration parser port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only captured text crosses this bounded port.  Rust parses schema/legacy
;; import; the initiating editor config service alone publishes its result.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)

(defconst kargu-bridge-config-max-source-bytes (* 64 1024)
  "Maximum UTF-8 configuration text bytes accepted by the native parser.")

(defun kargu-bridge-config--ready (task application source generation connection failure)
  "Parse SOURCE for TASK/APPLICATION/GENERATION on CONNECTION, or report FAILURE."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((<= (kargu-async-task-deadline task) (float-time))
    (kargu-async-finish task nil (kargu-bridge--fault "configuration_deadline")))
   ((not (kargu-bridge-application-current-p application connection))
    (kargu-async-finish task nil (kargu-bridge--fault "owner_closed")))
   ((not (member "configuration_parse" (append (kargu-bridge-connection-capabilities connection) nil)))
    (kargu-async-finish task nil (kargu-bridge--fault "unsupported_configuration_parse")))
   (t
    (let ((id (kargu-bridge-call
               connection "configuration/parse"
               (kargu-bridge--object
                "connection_epoch" (kargu-bridge-connection-epoch connection)
                "arguments" (kargu-bridge--object "source" source "generation" generation))
               (kargu-async-wrap
                task (lambda (value error-data)
                       (cond
                        ((<= (kargu-async-task-deadline task) (float-time))
                         (kargu-async-finish task nil (kargu-bridge--fault "configuration_deadline")))
                        ((kargu-bridge-application-current-p application connection)
                         (kargu-async-finish task value error-data))
                        (t (kargu-async-finish task nil (kargu-bridge--fault "owner_closed"))))))
               :owner (kargu-async-task-buffer task)
               :timeout (max 0.001 (- (kargu-async-task-deadline task) (float-time))))))
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))

(cl-defun kargu-bridge-config-parse (source generation callback &key parent application)
  "Parse captured SOURCE for GENERATION into CALLBACK under PARENT/APPLICATION.
CALLBACK receives (DTO FAILURE).  No file IO or config publication occurs here."
  (kargu-contract-assert #'stringp source)
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert #'kargu-application-p application)
  (let* ((source (copy-sequence source))
         (task (kargu-async-start (kargu-application-wrap application callback)
                                :parent parent :owner nil :timeout 5.0))
         (binding (gethash :native-core (kargu-application-services application)))
         (ready (kargu-async-wrap
                 task (lambda (connection failure)
                        (kargu-bridge-config--ready task application source generation connection failure)))))
    (kargu-async-add-cleanup task (lambda () (clear-string source)))
    (when (kargu-async-pending-p task)
      (cond
       ((> (string-bytes source) kargu-bridge-config-max-source-bytes)
        (kargu-async-finish task nil (kargu-bridge--fault "configuration_limit")))
       (binding
        (let ((connection (kargu-bridge-application-connection binding)))
          (funcall ready connection (unless (kargu-bridge-application-current-p application connection)
                                      (kargu-bridge--fault "owner_closed")))))
       (t (kargu-async-add-cleanup task (kargu-bridge-ensure ready)))))
    task))

(provide 'kargu/bridge/config)
;;; config.el ends here
