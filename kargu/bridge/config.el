;;; config.el --- Owned readonly native configuration file port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only explicit local file candidates cross this bounded port.  Rust reads and
;; parses them; the initiating editor config service alone publishes its result.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)

(defun kargu-bridge-config--ready (task application paths generation connection failure)
  "Read PATHS for TASK/APPLICATION/GENERATION on CONNECTION, or report FAILURE."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((<= (kargu-async-task-deadline task) (float-time))
    (kargu-async-finish task nil (kargu-bridge--fault "configuration_deadline")))
   ((not (kargu-bridge-application-current-p application connection))
    (kargu-async-finish task nil (kargu-bridge--fault "owner_closed")))
   ((not (member "configuration_read" (append (kargu-bridge-connection-capabilities connection) nil)))
    (kargu-async-finish task nil (kargu-bridge--fault "unsupported_configuration_read")))
   (t
    (let ((id (kargu-bridge-call
               connection "configuration/read"
               (kargu-bridge--object
                "connection_epoch" (kargu-bridge-connection-epoch connection)
                "arguments" (kargu-bridge--object
                             "paths" (vconcat paths) "generation" generation
                             "timeout_ms" (max 1 (min 5000 (floor (* 1000 (- (kargu-async-task-deadline task) (float-time))))))))
               (kargu-async-wrap
                task (lambda (value error-data)
                       (cond
                        ((<= (kargu-async-task-deadline task) (float-time))
                         (kargu-async-finish task nil (kargu-bridge--fault "configuration_deadline")))
                        ((and (not error-data)
                              (not (and (hash-table-p value) (member (gethash "path" value) paths))))
                         (kargu-async-finish task nil (kargu-bridge--fault "invalid_configuration_path")))
                        ((kargu-bridge-application-current-p application connection)
                         (kargu-async-finish task value error-data))
                        (t (kargu-async-finish task nil (kargu-bridge--fault "owner_closed"))))))
               :owner (kargu-async-task-buffer task)
               :timeout (max 0.001 (- (kargu-async-task-deadline task) (float-time))))))
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))

(cl-defun kargu-bridge-config-read (paths generation callback &key parent application)
  "Read captured PATHS for GENERATION into CALLBACK under PARENT/APPLICATION.
CALLBACK receives (DTO FAILURE).  Only Rust performs file IO.
This port never publishes configuration."
  (kargu-contract-assert #'listp paths)
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert #'kargu-application-p application)
  (let* ((valid (and (<= 1 (length paths) 8)
                     (cl-every (lambda (path) (and (stringp path) (file-name-absolute-p path)
                                                  (not (file-remote-p path)))) paths)))
         (paths (and valid (mapcar (lambda (path) (expand-file-name (copy-sequence path))) paths)))
         (task (kargu-async-start (kargu-application-wrap application callback)
                                :parent parent :owner nil :timeout 5.0))
         (binding (gethash :native-core (kargu-application-services application)))
         (ready (kargu-async-wrap
                 task (lambda (connection failure)
                        (kargu-bridge-config--ready task application paths generation connection failure)))))
    (when (kargu-async-pending-p task)
      (cond
       ((not valid)
        (kargu-async-finish task nil (kargu-bridge--fault "invalid_configuration_paths")))
       (binding
        (let ((connection (kargu-bridge-application-connection binding)))
          (funcall ready connection (unless (kargu-bridge-application-current-p application connection)
                                      (kargu-bridge--fault "owner_closed")))))
       (t (kargu-async-add-cleanup task (kargu-bridge-ensure ready)))))
    task))

(provide 'kargu/bridge/config)
;;; config.el ends here
