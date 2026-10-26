;;; application.el --- Editor leases for native application scopes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each editor application owns a native service identity on one connection.
;; This is not yet a user-conversation import or native agent run.  Only lease
;; delivery lives here; admission, revocation and drain are owned by Rust.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/application/coordinator)

(cl-defstruct (kargu-bridge-application (:constructor kargu-bridge-application--make))
  "One application's connection-bound native service lease."
  connection scope waiters close-waiters finalizer fault
  (identity (make-symbol "kargu-native-application")) (state :starting))

(defun kargu-bridge-application--copy-scope (scope)
  "Return detached native SCOPE identifiers, never shared mutable strings."
  (kargu-bridge--object
   "application_id" (copy-sequence (gethash "application_id" scope))
   "session_id" (copy-sequence (gethash "session_id" scope))))

(defun kargu-bridge-application--notify (binding error-data)
  "Take BINDING's scope waiters and deliver ERROR-DATA exactly once."
  (let ((waiters (kargu-bridge-application-waiters binding)))
    (setf (kargu-bridge-application-waiters binding) nil)
    (dolist (ticket (nreverse waiters))
      (let ((callback (car ticket)))
        (setcar ticket nil)
        (let ((failure (or error-data
                           (unless (and (eq (kargu-bridge-application-state binding) :ready)
                                        (eq (kargu-bridge-status (kargu-bridge-application-connection binding)) 'ready))
                             (kargu-bridge--fault "owner_closed")))))
          (kargu-bridge--callback callback
                                  (unless failure (kargu-bridge-application--copy-scope
                                                   (kargu-bridge-application-scope binding))) failure))))))

(defun kargu-bridge-application--dispose (connection identity)
  "Best-effort cleanup of unreachable idle IDENTITY on existing CONNECTION.
Never start a process here.  Active work and explicit close use owned drain."
  (when-let* ((id (get identity 'id))
              ((eq (kargu-bridge-status connection) 'ready)))
    (put identity 'id nil)
    (kargu-bridge-call connection "application/close"
                       (kargu-bridge--object "application_id" id) #'ignore)))

(defun kargu-bridge-application--failed (binding error-data)
  "Fail BINDING's startup with ERROR-DATA without retaining an orphan scope."
  (let ((closing (eq (kargu-bridge-application-state binding) :closing)))
    (setf (kargu-bridge-application-state binding) (if closing :closing :failed)
          (kargu-bridge-application-fault binding) (unless closing error-data))
    (kargu-bridge-application--notify binding error-data)
    (if (get (kargu-bridge-application-identity binding) 'id)
        (kargu-bridge-application--close-native binding)
      (when closing (setf (kargu-bridge-application-state binding) :closed))
      (let ((waiters (kargu-bridge-application-close-waiters binding)))
        (setf (kargu-bridge-application-close-waiters binding) nil)
        (dolist (callback waiters) (kargu-bridge--callback callback nil error-data))))))

(defun kargu-bridge-application--close-native (binding)
  "Close BINDING's known identity after startup or explicit revocation."
  (let* ((identity (kargu-bridge-application-identity binding))
         (connection (kargu-bridge-application-connection binding))
         (id (get identity 'id)))
    (when (and id (not (get identity 'closing)))
      (put identity 'closing t)
      (kargu-bridge-call
       connection "application/close" (kargu-bridge--object "application_id" id)
       (lambda (result error-data)
         (unless (or error-data (and (hash-table-p result) (equal (gethash "status" result) "closed")))
           (setq error-data (kargu-bridge--fault "protocol_error")))
         (unless error-data (put identity 'id nil))
         (setf (kargu-bridge-application-state binding)
               (if (or error-data (kargu-bridge-application-fault binding)) :failed :closed)
               (kargu-bridge-application-scope binding) nil)
         (let ((waiters (kargu-bridge-application-close-waiters binding)))
           (setf (kargu-bridge-application-close-waiters binding) nil)
           (dolist (callback waiters) (kargu-bridge--callback callback nil error-data))))
       :timeout :unlimited))))

(defun kargu-bridge-application--start (binding)
  "Create BINDING's native application and then its passive service session."
  (let ((connection (kargu-bridge-application-connection binding)))
    (kargu-bridge-call
     connection "application/create" (kargu-bridge--object)
     (lambda (application error-data)
       (let ((id (and (hash-table-p application) (gethash "application_id" application))))
         (cond
          (error-data (kargu-bridge-application--failed binding error-data))
          ((not (and (stringp id) (string-prefix-p "app_" id)))
           (kargu-bridge-application--failed binding (kargu-bridge--fault "protocol_error")))
          (t
           (put (kargu-bridge-application-identity binding) 'id (copy-sequence id))
           (if (eq (kargu-bridge-application-state binding) :closing)
               (kargu-bridge-application--close-native binding)
             (kargu-bridge-call
              connection "session/create" (kargu-bridge--object "application_id" id)
              (lambda (scope failure)
                (cond
                 ((not (eq (kargu-bridge-application-state binding) :starting)) nil)
                 (failure (kargu-bridge-application--failed binding failure))
                 ((not (and (hash-table-p scope) (equal (gethash "application_id" scope) id)
                            (stringp (gethash "session_id" scope))
                            (string-prefix-p "sess_" (gethash "session_id" scope))))
                  (kargu-bridge-application--failed binding (kargu-bridge--fault "protocol_error")))
                 (t
                  (setf (kargu-bridge-application-scope binding) (kargu-bridge-application--copy-scope scope)
                        (kargu-bridge-application-state binding) :ready)
                  (kargu-bridge-application--notify binding nil)))))))))))))

(defun kargu-bridge-application-ensure (connection application callback)
  "Deliver APPLICATION's native scope on CONNECTION to CALLBACK.
Return a waiter cleanup; cancelling one waiter cannot revoke a sibling lease."
  (let* ((services (kargu-application-services application))
         (binding (gethash :native-core services)))
    (cond
     ((not (eq (kargu-bridge-status connection) 'ready))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "disconnected")) #'ignore)
     ((not (cl-every (lambda (capability) (member capability (append (kargu-bridge-connection-capabilities connection) nil)))
                     '("application_lifecycle" "session_lifecycle" "application_close")))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "unsupported_application_scope"
                                                                "Required native application capability unavailable; rebuild kargu-core")) #'ignore)
     (t
      (when (or (null binding) (not (eq connection (kargu-bridge-application-connection binding)))
                (and (eq (kargu-bridge-application-state binding) :failed)
                     (kargu-bridge-application-fault binding)
                     (not (get (kargu-bridge-application-identity binding) 'id))))
        (setq binding (kargu-bridge-application--make :connection connection))
        (let ((identity (kargu-bridge-application-identity binding)))
          (setf (kargu-bridge-application-finalizer binding)
                (make-finalizer (lambda () (kargu-bridge-application--dispose connection identity)))))
        (puthash :native-core binding services)
        (kargu-bridge-application--start binding))
      (pcase (kargu-bridge-application-state binding)
        (:ready
         (kargu-bridge--callback callback (kargu-bridge-application--copy-scope
                                           (kargu-bridge-application-scope binding)) nil) #'ignore)
        (:starting
         (if (>= (length (kargu-bridge-application-waiters binding)) kargu-bridge--max-pending)
             (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "resource_limit")) #'ignore)
           (let ((ticket (list callback)))
             (push ticket (kargu-bridge-application-waiters binding))
             (lambda ()
               (setcar ticket nil)
               (setf (kargu-bridge-application-waiters binding)
                     (delq ticket (kargu-bridge-application-waiters binding)))))))
        (_ (kargu-bridge--callback callback nil (or (kargu-bridge-application-fault binding)
                                                    (kargu-bridge--fault "owner_closed"))) #'ignore))))))

(defun kargu-bridge-application-scope-equal-p (left right)
  "Compare detached native scope fields in LEFT and RIGHT, not hash identity."
  (and (hash-table-p left) (hash-table-p right)
       (cl-every (lambda (key)
                   (and (stringp (gethash key left)) (stringp (gethash key right))
                        (equal (gethash key left) (gethash key right))))
                 '("application_id" "session_id"))))

(defun kargu-bridge-application-current-p (application connection)
  "Check APPLICATION has not lost or replaced the captured CONNECTION lease."
  (let ((binding (gethash :native-core (kargu-application-services application))))
    (and (kargu-bridge-connection-p connection)
         (eq (kargu-bridge-status connection) 'ready)
         (or (null binding)
             (and (eq connection (kargu-bridge-application-connection binding))
                  (memq (kargu-bridge-application-state binding) '(:starting :ready)))))))

(defun kargu-bridge-application-current-scope (application connection)
  "Read APPLICATION's live scope on exact CONNECTION without starting a core.
The returned identifiers are detached; nil means the lease is not current."
  (let ((binding (gethash :native-core (kargu-application-services application))))
    (when (and binding (eq connection (kargu-bridge-application-connection binding))
               (eq (kargu-bridge-status connection) 'ready)
               (eq (kargu-bridge-application-state binding) :ready))
      (kargu-bridge-application--copy-scope (kargu-bridge-application-scope binding)))))

(defun kargu-bridge-application-close (application &optional callback)
  "Revoke APPLICATION's native lease; invoke CALLBACK only after core drain.
No replacement core is started to close an old lease."
  (let ((binding (gethash :native-core (kargu-application-services application))))
    (cond
     ((or (null binding) (eq (kargu-bridge-application-state binding) :closed)
          (and (eq (kargu-bridge-application-state binding) :failed)
               (not (get (kargu-bridge-application-identity binding) 'id))))
      (when binding (setf (kargu-bridge-application-state binding) :closed
                          (kargu-bridge-application-fault binding) nil))
      (kargu-bridge--callback callback nil nil))
     ((>= (length (kargu-bridge-application-close-waiters binding)) kargu-bridge--max-pending)
      (kargu-bridge--callback callback nil (kargu-bridge--fault "resource_limit")))
     (t
      (when callback (push callback (kargu-bridge-application-close-waiters binding)))
      (setf (kargu-bridge-application-state binding) :closing
            (kargu-bridge-application-fault binding) nil)
      (kargu-bridge-application--notify binding (kargu-bridge--fault "owner_closed"))
      (kargu-bridge-application--close-native binding)))))

(provide 'kargu/bridge/application)
;;; application.el ends here
