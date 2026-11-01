;;; history.el --- Native edit history metadata reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read undo metadata on an existing application lease.  Rust owns eviction and
;; rollback eligibility.  This reader neither starts a core nor caches rights.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)

(defun kargu-bridge-edit-history--read (application arguments maximum callback parent &optional lease)
  "Page native metadata for APPLICATION using ARGUMENTS into CALLBACK.
MAXIMUM bounds DTO count; PARENT owns cancellation.
LEASE pins the original service owner."
  (let* ((lease (kargu-bridge-edit-history--copy-lease lease))
         (binding (gethash :native-core (kargu-application-services application)))
         (connection (if lease (plist-get lease :connection)
                       (and binding (kargu-bridge-application-connection binding))))
         (scope (if lease (plist-get lease :scope)
                  (and connection (kargu-bridge-application-current-scope application connection))))
         (epoch (if lease (plist-get lease :epoch)
                  (and connection (copy-sequence (kargu-bridge-connection-epoch connection)))))
         (revision (gethash "revision" arguments))
         (task (kargu-async-start (or callback #'ignore) :parent parent :timeout 30))
         (cursor 0) (sequence 0) active rows)
    (cl-labels
        ((fail (failure) (kargu-async-finish task nil failure))
         (current-p ()
           (and (kargu-async-pending-p task)
                (or (null lease) (eq application (plist-get lease :application)))
                (equal epoch (kargu-bridge-connection-epoch connection))
                (kargu-bridge-application-scope-equal-p
                 scope (kargu-bridge-application-current-scope application connection))))
         (cancel (id)
           (when (and id (equal epoch (kargu-bridge-connection-epoch connection)))
             (kargu-bridge-cancel connection id)))
         (read-page ()
           (if (not (current-p)) (fail (kargu-bridge--fault "stale_owner"))
             (puthash "offset" cursor arguments)
             (puthash "revision" (or revision :json-null) arguments)
             (let* ((generation (cl-incf sequence))
                    (id (kargu-bridge-call
                         connection "edit/history"
                         (kargu-bridge--object "scope" scope "arguments" (copy-hash-table arguments))
                         (kargu-async-wrap
                          task (lambda (page failure)
                                 (setq active nil)
                                 (receive-page page failure))))))
               ;; Inline completion can issue a newer page before this ID exists.
               (if (and (kargu-async-pending-p task) (= sequence generation))
                   (setq active id)
                 (cancel id)))))
         (receive-page (page failure)
           (cond
            (failure (fail failure))
            ((not (current-p)) (fail (kargu-bridge--fault "stale_owner")))
            (t
             (let* ((files (and (hash-table-p page) (gethash "files" page)))
                    (next (and (hash-table-p page) (gethash "next_offset" page)))
                    (version (and (hash-table-p page) (gethash "revision" page)))
                    (complete (and (hash-table-p page) (gethash "complete" page))))
               (if (not (and (vectorp files) (integerp next) (integerp version)
                             (>= version 0) (or (null revision) (= revision version))
                             (eql (gethash "offset" page) cursor)
                             (= next (+ cursor (length files))) (<= next maximum)
                             (memq complete '(t :json-false))
                             (or (eq complete t) (> next cursor))))
                   (fail (kargu-bridge--fault "invalid_edit_history"))
                 (setq revision version cursor next)
                 (mapc (lambda (row) (push row rows)) files)
                 (if (eq complete t)
                     (kargu-async-finish
                      task (list :revision revision :rows (nreverse rows)
                                 :connection connection :scope scope :epoch epoch))
                   (read-page))))))))
      (kargu-async-add-cleanup task (lambda () (cancel active) (setq active nil)))
      (cond
       ((or (null scope)
            (not (member "edit_history" (append (kargu-bridge-connection-capabilities connection) nil))))
        (fail (kargu-bridge--fault "unavailable")))
       ((not (or (and (null revision) (not (equal (gethash "action" arguments) "files")))
                 (and (integerp revision) (>= revision 0))))
        (fail (kargu-bridge--fault "invalid_edit_history")))
       (t (read-page))))
    task))

(cl-defun kargu-bridge-edit-history (application &key service-id edit-id revision callback parent lease)
  "Read APPLICATION's native undo metadata asynchronously into CALLBACK.
With EDIT-ID, read its files at the exact previously observed REVISION.
Otherwise read retained edit identities.  Return a cancellable task without
starting a core.  SERVICE-ID isolates services; LEASE pins the original owner."
  (let ((arguments (kargu-bridge--object
                    "action" (if edit-id "files" "list")
                    "service_id" (if service-id (copy-sequence service-id) :json-null)
                    "revision" revision)))
    (when edit-id (puthash "edit_id" (copy-sequence edit-id) arguments))
    (kargu-bridge-edit-history--read application arguments (if edit-id 256 16) callback parent lease)))

(defun kargu-bridge-edit-history-paths (application callback &optional service-id lease)
  "Read APPLICATION's retained undo paths into CALLBACK without local mirrors.
CALLBACK receives (PATHS FAILURE); a concurrent edit invalidates the read.
SERVICE-ID selects the service; LEASE pins its original connection and scope."
  (let ((service-id (and service-id (copy-sequence service-id)))
        (task (kargu-async-start callback :timeout 30))
        connection scope epoch revision remaining paths)
    (cl-labels
        ((finish (failure) (kargu-async-finish task (unless failure (nreverse paths)) failure))
         (current-p ()
           (and (kargu-async-pending-p task)
                (equal epoch (kargu-bridge-connection-epoch connection))
                (kargu-bridge-application-scope-equal-p
                 scope (kargu-bridge-application-current-scope application connection))))
         (next ()
           (cond
            ((not (current-p)) (finish (kargu-bridge--fault "stale_owner")))
            ((null remaining) (finish nil))
            (t
             (let ((edit (pop remaining)))
               (kargu-bridge-edit-history
                application :service-id service-id :edit-id (gethash "edit_id" edit) :revision revision :parent task :lease lease
                :callback (kargu-async-wrap task #'files-ready))))))
         (files-ready (value failure)
           (cond
            (failure (finish failure))
            ((not (current-p)) (finish (kargu-bridge--fault "stale_owner")))
            (t
             (dolist (row (plist-get value :rows))
               (let ((root (gethash "root" row)) (path (gethash "path" row)))
                 (unless (and (stringp root) (file-name-absolute-p root) (stringp path))
                   (error "Invalid native undo path"))
                 (cl-pushnew (expand-file-name path root) paths :test #'equal)))
             (next))))
         (edits-ready (value failure)
           (if failure (finish failure)
             (setq connection (plist-get value :connection) scope (plist-get value :scope)
                   epoch (plist-get value :epoch) revision (plist-get value :revision)
                   remaining (plist-get value :rows))
             (next))))
      (kargu-bridge-edit-history
       application :service-id service-id :parent task :lease lease :callback (kargu-async-wrap task #'edits-ready)))
    task))

(cl-defun kargu-bridge-edit-history-changes
    (application &key service-id revision pending-only callback parent lease)
  "Read APPLICATION's native change DTOs asynchronously into CALLBACK.
SERVICE-ID selects an edit service; REVISION pins a previous observation.
PENDING-ONLY filters files awaiting verification; Rust owns that selection.
PARENT owns cancellation; LEASE pins the original service owner."
  (kargu-bridge-edit-history--read
   application
   (kargu-bridge--object "action" "changes"
                        "service_id" (if service-id (copy-sequence service-id) :json-null)
                        "revision" revision
                        "pending_only" (if pending-only t :json-false))
   256 callback parent lease))

(defun kargu-bridge-edit-history--mutate (application arguments &optional callback lease)
  "Send ARGUMENTS on APPLICATION only through its captured LEASE.
When absent, capture the current binding.  Deliver a guarded ACK to CALLBACK."
  (let* ((binding (and application (gethash :native-core (kargu-application-services application))))
         (connection (and binding (kargu-bridge-application-connection binding)))
         (scope (and connection (kargu-bridge-application-current-scope application connection)))
         (lease (kargu-bridge-edit-history--copy-lease
                 (or lease (and scope (kargu-bridge-edit-history-capture-lease application connection scope)))))
         (connection (plist-get lease :connection))
         (receive (or callback #'ignore)))
    (if (and (eq application (plist-get lease :application))
             (kargu-bridge-edit-history-lease-current-p lease)
             (member "edit_history" (append (kargu-bridge-connection-capabilities connection) nil)))
        (kargu-bridge-call
         connection "edit/history"
         (kargu-bridge--object "scope" (plist-get lease :scope) "arguments" arguments)
         (lambda (value failure)
           (let ((current (kargu-bridge-edit-history-lease-current-p lease)))
             (funcall receive (and current value)
                      (or failure (unless current (kargu-bridge--fault "stale_owner")))))))
      (funcall receive nil (kargu-bridge--fault "unavailable")))))

(cl-defun kargu-bridge-edit-history-consume
    (application &key edit-id edit-revision file final-hash service-id callback lease)
  "Consume EDIT-ID, EDIT-REVISION, FILE and FINAL-HASH on APPLICATION.
SERVICE-ID and LEASE pin the original owner; deliver the ACK to CALLBACK."
  (kargu-bridge-edit-history--mutate
   application
   (kargu-bridge--object
    "action" "consume"
    "edit_id" edit-id
    "edit_revision" edit-revision
    "file" file
    "final_hash" (or final-hash :json-null)
    "service_id" (or service-id :json-null))
   callback lease))

(cl-defun kargu-bridge-edit-history-reset
    (application &key service-id callback lease)
  "Reset SERVICE-ID's consumed metadata on APPLICATION, preserving pending debt.
Snapshots are retained.  Use LEASE and deliver acknowledgement to CALLBACK."
  (kargu-bridge-edit-history--mutate
   application
   (kargu-bridge--object
    "action" "reset_changes"
    "service_id" (or service-id :json-null))
   callback lease))

(defun kargu-bridge-edit-history--copy-lease (lease)
  "Detach LEASE's mutable metadata before an asynchronous boundary."
  (when lease
    (list :connection (plist-get lease :connection)
          :epoch (copy-sequence (plist-get lease :epoch))
          :scope (kargu-bridge-application--copy-scope (plist-get lease :scope))
          :application (plist-get lease :application))))

(defun kargu-bridge-edit-history-capture-lease (application connection scope)
  "Capture APPLICATION's existing CONNECTION and SCOPE without acquiring a lease."
  (list :connection connection :epoch (copy-sequence (kargu-bridge-connection-epoch connection))
        :scope (kargu-bridge-application--copy-scope scope) :application application))

(defun kargu-bridge-edit-history-lease-current-p (lease)
  "Whether LEASE still identifies its original application, epoch and scope."
  (let ((connection (plist-get lease :connection)))
    (and connection (eq (kargu-bridge-status connection) 'ready)
         (equal (plist-get lease :epoch) (kargu-bridge-connection-epoch connection))
         (kargu-bridge-application-scope-equal-p
          (plist-get lease :scope)
          (kargu-bridge-application-current-scope (plist-get lease :application) connection)))))

(defun kargu-bridge-edit-history-close-service (application service-id &optional callback lease)
  "Revoke SERVICE-ID on APPLICATION, completing only after native drain.
Use captured LEASE when supplied; otherwise capture the current binding."
  (let* ((binding (and application (gethash :native-core (kargu-application-services application))))
         (connection (if lease (plist-get lease :connection)
                       (and binding (kargu-bridge-application-connection binding))))
         (scope (if lease (kargu-bridge-application--copy-scope (plist-get lease :scope))
                  (and connection (kargu-bridge-application-current-scope application connection))))
         (epoch (if lease (copy-sequence (plist-get lease :epoch))
                  (and connection (copy-sequence (kargu-bridge-connection-epoch connection)))))
         (task (kargu-async-start (or callback #'ignore) :parent nil :owner nil :timeout 30))
         (service-id (and (stringp service-id) (copy-sequence service-id)))
         active)
    (cl-labels
        ((current-p ()
           (and (kargu-async-pending-p task) service-id scope
                (or (null lease) (eq application (plist-get lease :application)))
                (equal epoch (kargu-bridge-connection-epoch connection))
                (kargu-bridge-application-scope-equal-p
                 scope (kargu-bridge-application-current-scope application connection))))
         (poll ()
           (if (not (current-p))
               (kargu-async-finish task nil (kargu-bridge--fault "stale_owner"))
             (let* ((received nil)
                    (id (kargu-bridge-call
                        connection "edit/history"
                        (kargu-bridge--object
                         "scope" scope "arguments"
                         (kargu-bridge--object "action" "close_service" "service_id" service-id))
                        (kargu-async-wrap task (lambda (value failure)
                                                (setq received t active nil)
                                                (receive value failure))))))
               (when (and (not received) id)
                 (if (kargu-async-pending-p task) (setq active id)
                   (when (equal epoch (kargu-bridge-connection-epoch connection))
                     (kargu-bridge-cancel connection id)))))))
         (receive (value failure)
           (cond
            (failure (kargu-async-finish task nil failure))
            ((not (current-p)) (kargu-async-finish task nil (kargu-bridge--fault "stale_owner")))
            ((not (and (hash-table-p value) (eq (gethash "closed" value) t)
                       (memq (gethash "drained" value) '(t :json-false))))
             (kargu-async-finish task nil (kargu-bridge--fault "invalid_edit_history")))
            ((eq (gethash "drained" value) t) (kargu-async-finish task value nil))
            (t (let ((timer (run-at-time 0.1 nil (kargu-async-wrap task #'poll))))
                 (kargu-async-add-cleanup task (lambda () (cancel-timer timer))))))))
      (kargu-async-add-cleanup
       task (lambda ()
              (when (and active (equal epoch (kargu-bridge-connection-epoch connection)))
                (kargu-bridge-cancel connection active))
              (setq active nil)))
      (poll))
    task))

(provide 'kargu/bridge/edit/history)
;;; history.el ends here
