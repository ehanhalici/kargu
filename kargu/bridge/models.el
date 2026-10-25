;;; models.el --- Native metadata publication tickets and UI observations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One exact native lease, serial bounded publications and passive detached UI
;; reads.  Barriers retain a particular submission, never the current queue tail.
;; This module does not parse metadata or merge overrides.  Only an explicit
;; publication may acquire a first core connection; getters remain passive.

;;; Code:

(require 'kargu/bridge/models/start)

(defun kargu-bridge-models--release (ticket)
  "Release TICKET's captured buffers exactly once after native drain."
  (unless (kargu-bridge-model-ticket-released ticket)
    (setf (kargu-bridge-model-ticket-released ticket) t)
    (when-let* ((cleanup (kargu-bridge-model-ticket-startup-cleanup ticket)))
      (setf (kargu-bridge-model-ticket-startup-cleanup ticket) nil)
      (funcall cleanup))
    (let ((service (kargu-bridge-model-ticket-service ticket)))
      (cl-decf (kargu-bridge-models-bytes service) (kargu-bridge-model-ticket-bytes ticket))
      (setf (kargu-bridge-model-ticket-source ticket) nil
            (kargu-bridge-model-ticket-specs ticket) nil
            (kargu-bridge-model-ticket-chunks ticket) nil))))

(defun kargu-bridge-models--complete (ticket view failure)
  "Accept TICKET's committed VIEW or FAILURE, then advance its owned queue."
  (unless (kargu-bridge-model-ticket-released ticket)
    (let* ((service (kargu-bridge-model-ticket-service ticket))
           (failure (or failure (unless (kargu-bridge-models--valid-p ticket)
                                  (kargu-bridge--fault "stale_metadata_owner")))))
      (when (and failure (or (kargu-bridge-model-ticket-commit-sent ticket)
                             (eq (kargu-bridge-model-ticket-phase ticket) :beginning)))
	(setf (kargu-bridge-models-fault service) failure))
      (when (and view (not failure))
        (let ((cell (make-symbol "kargu-native-model-view")))
          (put cell 'value view)
          (setf (kargu-bridge-models-view-cell service) cell
                (kargu-bridge-model-ticket-view-cell ticket) cell))
        (when (kargu-bridge-model-ticket-reconcile ticket)
          (setf (kargu-bridge-models-fault service) nil)))
      (when (eq (kargu-bridge-model-ticket-status ticket) :pending)
	(setf (kargu-bridge-model-ticket-status ticket) (if failure :failed :committed)
              (kargu-bridge-model-ticket-failure ticket) failure))
      (when (eq ticket (kargu-bridge-models-active service))
	(setf (kargu-bridge-models-active service) nil))
      (kargu-bridge-models--release ticket)
      (kargu-bridge-models--notify ticket (unless failure view) failure)
      (kargu-bridge-models--pump service))))

(defun kargu-bridge-models-cancel (ticket &optional failure)
  "Revoke TICKET's deliveries, draining uploads before another starts.
An issued commit cannot be undone; uncertainty refuses further publication."
  (when (eq (kargu-bridge-model-ticket-status ticket) :pending)
    (let* ((service (kargu-bridge-model-ticket-service ticket))
           (failure (or failure (kargu-bridge--fault "cancelled"))))
      (setf (kargu-bridge-model-ticket-cancel-reason ticket) failure
            (kargu-bridge-model-ticket-failure ticket) failure
            (kargu-bridge-model-ticket-status ticket) :cancelled)
      (kargu-bridge-models--notify ticket nil failure)
      (cond
       ((not (eq ticket (kargu-bridge-models-active service)))
        (setf (kargu-bridge-models-queue service) (delq ticket (kargu-bridge-models-queue service)))
        (kargu-bridge-models--release ticket))
       ((eq (kargu-bridge-model-ticket-phase ticket) :connecting)
        ;; No application resource was acquired; detach only this startup waiter.
        (kargu-bridge-models--complete ticket nil failure))))))

(defun kargu-bridge-models--pump (service)
  "Start at most one queued publication on SERVICE's single native lease."
  (unless (kargu-bridge-models-active service)
    (when-let* ((ticket (pop (kargu-bridge-models-queue service))))
      (setf (kargu-bridge-models-active service) ticket)
      (cond
       ((and (kargu-bridge-models-fault service) (not (kargu-bridge-model-ticket-reconcile ticket)))
        (kargu-bridge-models--complete ticket nil (kargu-bridge-models-fault service)))
       ((not (kargu-bridge-models--owned-p ticket))
        (kargu-bridge-models--complete ticket nil (or (kargu-bridge-model-ticket-cancel-reason ticket)
                                                    (kargu-bridge--fault "stale_metadata_owner"))))
       ((kargu-bridge-model-ticket-reconcile ticket)
        (if (kargu-bridge-models--current-p service) (kargu-bridge-models--head ticket)
          (kargu-bridge-models--complete ticket nil (kargu-bridge--fault "metadata_epoch_lost"))))
       ((null (kargu-bridge-models-connection service))
        (kargu-bridge-models--connect ticket))
       ((not (eq (kargu-bridge-status (kargu-bridge-models-connection service)) 'ready))
        (setf (kargu-bridge-models-fault service) (kargu-bridge--fault "metadata_epoch_lost"))
        (kargu-bridge-models--complete ticket nil (kargu-bridge-models-fault service)))
       (t (kargu-bridge-models--lease ticket))))))

(cl-defun kargu-bridge-models-submit (connection application provider source specs callback
						 &key owner valid-p reconcile)
  "Submit SOURCE and SPECS for PROVIDER using CONNECTION and APPLICATION.
Return a publication ticket; CALLBACK receives (VIEW FAILURE) once.  OWNER's
closure cancels only this submission.  VALID-P guards captured revisions.
Nil CONNECTION permits first startup, never a replacement of an acquired lease.
No fallback, reconnect or speculative publication occurs.  RECONCILE selects
read-only repair of the existing lease; see `kargu-bridge-models-reconcile'."
  (unless (and (stringp provider) (stringp source) (functionp callback)
               (vectorp specs)
               (or (null owner) (buffer-live-p owner)) (or (null valid-p) (functionp valid-p))
               (<= (string-bytes source) kargu-bridge-models--source-limit))
    (error "Invalid native metadata submission"))
  (when (> (string-bytes (json-serialize specs :null-object :json-null :false-object :json-false)) 131072)
    (error "Native metadata declaration limit exceeded"))
  (let* ((service (kargu-application-service
                   :native-models (lambda () (kargu-bridge-models--make
                                              :app application :connection connection)) application))
         (ticket (kargu-bridge-model-ticket--make
                  :service service :provider (copy-sequence provider) :source (copy-sequence source)
                  :specs (kargu-bridge-models--copy specs) :callback callback :owner owner :valid-p valid-p
                  :bytes (string-bytes source) :reconcile reconcile))
         (failure (cond
                   ((and connection (not (eq connection (kargu-bridge-models-connection service))))
                    (kargu-bridge--fault "metadata_epoch_lost"))
                   ((and connection (not (kargu-bridge-models--capable-p connection)))
                    (kargu-bridge--fault "unsupported_model_metadata"))
                   ((or (>= (length (kargu-bridge-models-queue service)) 32)
                        (> (+ (kargu-bridge-models-bytes service) (string-bytes source))
                           kargu-bridge-models--view-limit))
                    (kargu-bridge--fault "resource_limit")))))
    (setf (kargu-bridge-models-latest service) ticket)
    (cl-incf (kargu-bridge-models-bytes service) (kargu-bridge-model-ticket-bytes ticket))
    (if failure
        (progn
          (setf (kargu-bridge-model-ticket-status ticket) :failed
                (kargu-bridge-model-ticket-failure ticket) failure)
          (kargu-bridge-models--release ticket)
          (kargu-bridge-models--notify ticket nil failure))
      (setf (kargu-bridge-model-ticket-timer ticket)
            (run-at-time 60 nil #'kargu-bridge-models-cancel ticket (kargu-bridge--fault "timeout")))
      (when owner
        (let ((cleanup (lambda () (kargu-bridge-models-cancel ticket (kargu-bridge--fault "owner_closed")))))
          (setf (kargu-bridge-model-ticket-cleanup ticket) cleanup)
          (with-current-buffer owner
            (add-hook 'kill-buffer-hook cleanup nil t)
            (add-hook 'change-major-mode-hook cleanup nil t))))
      (setf (kargu-bridge-models-queue service) (nconc (kargu-bridge-models-queue service) (list ticket)))
      (kargu-bridge-models--pump service))
    ticket))

(cl-defun kargu-bridge-models-publish (application provider source specs callback &key owner valid-p)
  "Capture a publication for APPLICATION before first startup can yield.
SOURCE, SPECS, PROVIDER and OWNER are captured by `kargu-bridge-models-submit'.
CALLBACK receives (VIEW FAILURE).  Return the exact preparation-barrier ticket.
An existing native application connection is reused, never replaced.  VALID-P
guards the originating revision; passive readers never call this operation."
  (let* ((services (kargu-application-services application))
         (service (gethash :native-models services))
         (binding (gethash :native-core services))
         (connection (if service (kargu-bridge-models-connection service)
                       (and binding (kargu-bridge-application-connection binding)))))
    (kargu-bridge-models-submit connection application provider source specs callback
                                :owner owner :valid-p valid-p)))

(defun kargu-bridge-models-snapshot (application)
  "Return APPLICATION's detached last committed view without IO or core startup."
  (when-let* ((service (gethash :native-models (kargu-application-services application)))
              ((kargu-bridge-models--current-p service)))
    (kargu-bridge-models--copy (kargu-bridge-models--view service))))

(defun kargu-bridge-models-reconcile (application callback)
  "Explicitly repair APPLICATION's view on its existing native lease.
CALLBACK receives (VIEW FAILURE).  Never start a core, replay an update or
reset an uncertain revision to zero.  Return the read-only publication ticket."
  (let ((service (gethash :native-models (kargu-application-services application))))
    (if (not (and service (kargu-bridge-models--current-p service)))
        (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "metadata_epoch_lost")) nil)
      (kargu-bridge-models-submit (kargu-bridge-models-connection service) application
                                  "" "" [] callback :reconcile t))))

(defun kargu-bridge-models-capture (application)
  "Capture APPLICATION's latest submission for a preparation barrier, without IO."
  (when-let* ((service (gethash :native-models (kargu-application-services application))))
    (kargu-bridge-models-latest service)))

(defun kargu-bridge-models-await (ticket callback)
  "Await exactly TICKET in CALLBACK, never a later submission or queue tail.
Return a detachable waiter cleanup; it does not cancel a shared publication."
  (let ((waiter (list callback)))
    (pcase (kargu-bridge-model-ticket-status ticket)
      (:pending
       (if (>= (length (kargu-bridge-model-ticket-waiters ticket)) 128)
           (kargu-bridge--callback callback nil (kargu-bridge--fault "resource_limit"))
         (push waiter (kargu-bridge-model-ticket-waiters ticket))))
      (:committed
       (if (kargu-bridge-models--current-p (kargu-bridge-model-ticket-service ticket))
           (kargu-bridge--callback callback (kargu-bridge-model-ticket-view ticket) nil)
         (kargu-bridge--callback callback nil (kargu-bridge--fault "metadata_epoch_lost"))))
      (_ (kargu-bridge--callback callback nil (kargu-bridge-models--copy
                                               (kargu-bridge-model-ticket-failure ticket)))))
    (lambda ()
      (setcar waiter nil)
      (setf (kargu-bridge-model-ticket-waiters ticket)
            (delq waiter (kargu-bridge-model-ticket-waiters ticket))))))

(provide 'kargu/bridge/models)
;;; models.el ends here
