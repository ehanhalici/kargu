;;; conversation.el --- Per-chat native conversation leases -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A chat owns an opaque Rust session distinct from the application's service
;; session.  This port maps editor lifetimes to native handles; Rust owns history,
;; run admission, revocation and actual resource drain.  A close acknowledgement
;; revokes a session; it is never evidence that its workers have joined.

;;; Code:

(require 'cl-lib)
(require 'kargu/core/session)
(require 'kargu/bridge/application)

(cl-defstruct (kargu-bridge-conversation (:constructor kargu-bridge-conversation--make))
  "An editor chat's exact connection/application-bound native conversation."
  connection epoch application service-scope scope waiters cleanup fault
  (selection-revision 0)
  (mode-revision 0)
  (state :starting))

(defun kargu-bridge-conversation--current-p (binding)
  "Check BINDING still belongs to its captured native application lease."
  (and (equal (kargu-bridge-conversation-epoch binding)
              (kargu-bridge-connection-epoch (kargu-bridge-conversation-connection binding)))
       (kargu-bridge-application-scope-equal-p
        (kargu-bridge-conversation-service-scope binding)
        (kargu-bridge-application-current-scope
         (kargu-bridge-conversation-application binding)
         (kargu-bridge-conversation-connection binding)))))

(defun kargu-bridge-conversation--notify (binding failure)
  "Deliver BINDING's waiters once with detached handles or FAILURE."
  (let ((waiters (kargu-bridge-conversation-waiters binding)))
    (setf (kargu-bridge-conversation-waiters binding) nil)
    (dolist (ticket (nreverse waiters))
      (let ((callback (car ticket))
            (failure (or failure
                         (unless (and (eq (kargu-bridge-conversation-state binding) :ready)
                                      (kargu-bridge-conversation--current-p binding))
                           (kargu-bridge--fault "owner_closed")))))
        (setcar ticket nil)
        (kargu-bridge--callback
         callback (unless failure (kargu-bridge-application--copy-scope
                                   (kargu-bridge-conversation-scope binding))) failure)))))

(defun kargu-bridge-conversation--close (binding)
  "Revoke BINDING on its original connection without starting another core."
  (unless (memq (kargu-bridge-conversation-state binding) '(:closing :closed))
    (setf (kargu-bridge-conversation-state binding) :closing)
    (when-let* ((cleanup (kargu-bridge-conversation-cleanup binding)))
      (setf (kargu-bridge-conversation-cleanup binding) nil)
      (funcall cleanup))
    (kargu-bridge-conversation--notify binding (kargu-bridge--fault "owner_closed"))
    ;; A pending create must retain its callback to revoke the late native ID.
    (when (kargu-bridge-conversation-scope binding)
      (kargu-bridge-conversation--revoke binding))))

(defun kargu-bridge-conversation--revoke (binding)
  "Send BINDING's known session ID to the captured connection for revocation."
  (let ((connection (kargu-bridge-conversation-connection binding)))
    (if (not (and (eq (kargu-bridge-status connection) 'ready)
                  (equal (kargu-bridge-conversation-epoch binding)
                         (kargu-bridge-connection-epoch connection))))
        (setf (kargu-bridge-conversation-state binding) :closed)
      (kargu-bridge-call
       connection "session/close"
       (kargu-bridge-application--copy-scope (kargu-bridge-conversation-scope binding))
       (lambda (_result failure)
         (setf (kargu-bridge-conversation-state binding) (if failure :failed :closed)
               (kargu-bridge-conversation-fault binding) failure))))))

(defun kargu-bridge-conversation-retire (session)
  "Revoke SESSION's editor leases, retaining tombstones against late callbacks."
  (setf (kargu-session-native-retired session) t)
  (maphash (lambda (_application binding) (kargu-bridge-conversation--close binding))
           (kargu-session-native-conversations session)))

(add-hook 'kargu-session-before-replace-hook #'kargu-bridge-conversation-retire)

(defun kargu-bridge-conversation--start (binding)
  "Create BINDING's native session in its existing application."
  (kargu-bridge-call
   (kargu-bridge-conversation-connection binding) "session/create"
   (kargu-bridge--object "application_id"
                        (gethash "application_id" (kargu-bridge-conversation-service-scope binding)))
   (lambda (scope failure)
     (cond
      (failure
       (setf (kargu-bridge-conversation-state binding) :failed
             (kargu-bridge-conversation-fault binding) failure)
       (kargu-bridge-conversation--notify binding failure))
      ((not (and (hash-table-p scope) (= (hash-table-count scope) 2)
                 (equal (gethash "application_id" scope)
                        (gethash "application_id" (kargu-bridge-conversation-service-scope binding)))
                 (stringp (gethash "session_id" scope))
                 (string-prefix-p "sess_" (gethash "session_id" scope))
                 (not (equal (gethash "session_id" scope)
                             (gethash "session_id" (kargu-bridge-conversation-service-scope binding))))))
       (setf (kargu-bridge-conversation-state binding) :failed
             (kargu-bridge-conversation-fault binding) (kargu-bridge--fault "protocol_error"))
       (kargu-bridge-conversation--notify binding (kargu-bridge-conversation-fault binding)))
      (t
       (setf (kargu-bridge-conversation-scope binding) (kargu-bridge-application--copy-scope scope))
       (if (or (eq (kargu-bridge-conversation-state binding) :closing)
               (not (kargu-bridge-conversation--current-p binding)))
           (progn
             (setf (kargu-bridge-conversation-state binding) :closing)
             (kargu-bridge-conversation--notify binding (kargu-bridge--fault "owner_closed"))
             (kargu-bridge-conversation--revoke binding))
         (setf (kargu-bridge-conversation-state binding) :ready)
         (kargu-bridge-conversation--notify binding nil)))))))

(defun kargu-bridge-conversation-current-scope (application session connection)
  "Read SESSION's native conversation for APPLICATION on exact CONNECTION.
No session is created here; a missing or retired lease returns nil."
  (when-let* (((not (kargu-session-native-retired session)))
              (binding (gethash application (kargu-session-native-conversations session)))
              ((eq connection (kargu-bridge-conversation-connection binding)))
              ((eq (kargu-bridge-conversation-state binding) :ready))
              ((kargu-bridge-conversation--current-p binding)))
    (kargu-bridge-application--copy-scope (kargu-bridge-conversation-scope binding))))

(defun kargu-bridge-conversation-ensure (connection application session service-scope callback)
  "Deliver SESSION's conversation lease to CALLBACK (SCOPE FAILURE).
CONNECTION, APPLICATION and SERVICE-SCOPE must be the captured service lease.
Return a waiter cleanup; cancelling a waiter cannot cancel a sibling's lease."
  (let* ((table (kargu-session-native-conversations session))
         (binding (gethash application table)))
    (cond
     ((or (kargu-session-native-retired session)
          (not (kargu-bridge-application-scope-equal-p
                service-scope (kargu-bridge-application-current-scope application connection))))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "owner_closed")) #'ignore)
     ((and binding (or (not (eq connection (kargu-bridge-conversation-connection binding)))
                       (not (equal (kargu-bridge-conversation-epoch binding)
                                   (kargu-bridge-connection-epoch connection)))
                       (not (kargu-bridge-application-scope-equal-p
                             service-scope (kargu-bridge-conversation-service-scope binding)))))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "owner_closed")) #'ignore)
     ((and (null binding) (>= (hash-table-count table) kargu-bridge--max-pending))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "resource_limit")) #'ignore)
     (t
      (unless binding
        (setq binding (kargu-bridge-conversation--make
                       :connection connection :application application
                       :epoch (copy-sequence (kargu-bridge-connection-epoch connection))
                       :service-scope (kargu-bridge-application--copy-scope service-scope)))
        (puthash application binding table)
        (let* ((origin (current-buffer))
               (retire (lambda () (kargu-bridge-conversation-retire session))))
          (add-hook 'kill-buffer-hook retire nil t)
          (add-hook 'change-major-mode-hook retire nil t)
          (setf (kargu-bridge-conversation-cleanup binding)
                (lambda () (when (buffer-live-p origin)
                             (with-current-buffer origin
                               (remove-hook 'kill-buffer-hook retire t)
                               (remove-hook 'change-major-mode-hook retire t))))))
        (kargu-bridge-conversation--start binding))
      (pcase (kargu-bridge-conversation-state binding)
        (:ready
         (kargu-bridge--callback callback (kargu-bridge-application--copy-scope
                                         (kargu-bridge-conversation-scope binding)) nil) #'ignore)
        (:starting
         (if (>= (length (kargu-bridge-conversation-waiters binding)) kargu-bridge--max-pending)
             (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "resource_limit")) #'ignore)
           (let ((ticket (list callback)))
             (push ticket (kargu-bridge-conversation-waiters binding))
             (lambda ()
               (setcar ticket nil)
               (setf (kargu-bridge-conversation-waiters binding)
                     (delq ticket (kargu-bridge-conversation-waiters binding)))))))
        (_ (kargu-bridge--callback callback nil (or (kargu-bridge-conversation-fault binding)
                                                   (kargu-bridge--fault "owner_closed"))) #'ignore))))))

(defun kargu-bridge-conversation-with (session callback)
  "Deliver SESSION's conversation lease for the current buffer's application.
CALLBACK receives (CONNECTION APPLICATION SCOPE FAILURE) exactly once.
The current buffer owns the lease: the core connection, the application
service and the conversation are ensured in that order."
  (let ((application (kargu-application-context))
        (origin (current-buffer))
        (fail (lambda (failure) (funcall callback nil nil nil failure))))
    (kargu-bridge-ensure
     (lambda (connection failure)
       (if failure
           (funcall fail failure)
         (kargu-bridge-application-ensure
          connection application
          (lambda (service failure)
            (cond
             (failure (funcall fail failure))
             ((not (buffer-live-p origin))
              (funcall fail (kargu-bridge--fault "owner_closed")))
             (t
              (with-current-buffer origin
                (kargu-bridge-conversation-ensure
                 connection application session service
                 (lambda (scope failure)
                   (if failure
                       (funcall fail failure)
                     (funcall callback connection application scope nil))))))))))))))

(provide 'kargu/bridge/conversation)
;;; conversation.el ends here
