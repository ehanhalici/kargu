;;; start.el --- First-intent native metadata acquisition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Register the publication before shared sidecar startup can yield.  Startup
;; waiters may detach; acquired application leases never silently reconnect.
;; This module has no metadata parsing, revision guessing or replay policy.

;;; Code:

(require 'kargu/bridge/models/transfer)

(defun kargu-bridge-models--capable-p (connection)
  "Whether explicit CONNECTION supports the complete publication protocol."
  (and connection
       (cl-every (lambda (capability)
                   (member capability (append (kargu-bridge-connection-capabilities connection) nil)))
                 '("model_metadata" "model_metadata_projection"))))

(defun kargu-bridge-models--lease (ticket)
  "Acquire TICKET's application lease only on its captured ready connection."
  (let* ((service (kargu-bridge-model-ticket-service ticket))
         (connection (kargu-bridge-models-connection service))
         (binding (gethash :native-core
                           (kargu-application-services (kargu-bridge-models-app service))))
         (owned (kargu-bridge-models--owned-p ticket))
         (failure (cond
                   ((not owned)
                    (or (kargu-bridge-model-ticket-cancel-reason ticket)
                        (kargu-bridge--fault "stale_metadata_owner")))
                   ((or (not connection) (not (eq (kargu-bridge-status connection) 'ready))
                        (and binding (not (eq connection (kargu-bridge-application-connection binding)))))
                    (kargu-bridge--fault "metadata_epoch_lost"))
                   ((not (kargu-bridge-models--capable-p connection))
                    (kargu-bridge--fault "unsupported_model_metadata")))))
    (cond
     (failure
      ;; An owner revoked before acquisition has no native uncertainty.
      (when owned
        (setf (kargu-bridge-models-fault service) failure))
      (kargu-bridge-models--complete ticket nil failure))
     ((kargu-bridge-models-scope service) (kargu-bridge-models--ready ticket))
     (t
      (setf (kargu-bridge-model-ticket-phase ticket) :leasing)
      (let (delivered)
        (kargu-bridge-application-ensure
         connection (kargu-bridge-models-app service)
         (lambda (scope failure)
           (unless delivered
             (setq delivered t)
             (if failure
                 (progn (setf (kargu-bridge-models-fault service) failure)
                        (kargu-bridge-models--complete ticket nil failure))
               (setf (kargu-bridge-models-scope service) (kargu-bridge-application--copy-scope scope))
               (kargu-bridge-models--ready ticket))))))))))

(defun kargu-bridge-models--ready (ticket)
  "Start TICKET's explicit read or update after acquiring its exact lease."
  (if (kargu-bridge-model-ticket-observe ticket)
      (kargu-bridge-models--head ticket)
    (kargu-bridge-models--begin ticket)))

(defun kargu-bridge-models--connect (ticket)
  "Acquire a first connection for already registered TICKET, never reconnect."
  (let ((service (kargu-bridge-model-ticket-service ticket)) delivered)
    (setf (kargu-bridge-model-ticket-phase ticket) :connecting)
    (let ((cleanup
           (kargu-bridge-ensure
            (lambda (connection failure)
              (unless (or delivered (kargu-bridge-model-ticket-released ticket))
                (setq delivered t)
                (if (or failure (not connection))
                    (let ((failure (or failure (kargu-bridge--fault "startup_failed"))))
                      (setf (kargu-bridge-models-fault service) failure)
                      (kargu-bridge-models--complete ticket nil failure))
                  (setf (kargu-bridge-models-connection service) connection)
                  (kargu-bridge-models--lease ticket)))))))
      ;; The ready callback may have completed synchronously during ensure.
      (if (or delivered (kargu-bridge-model-ticket-released ticket))
          (funcall cleanup)
        (setf (kargu-bridge-model-ticket-startup-cleanup ticket) cleanup)))))

(provide 'kargu/bridge/models/start)
;;; start.el ends here
