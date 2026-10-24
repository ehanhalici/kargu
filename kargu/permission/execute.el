;;; execute.el --- Owned single-use approval continuations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Prepare once, ask once, and enter the captured continuation at most once.
;; A delayed decision cannot borrow another session, directory or environment.

;;; Code:

(require 'kargu/permission/policy)
(require 'kargu/contract/assert)
(require 'kargu/core/session)
(require 'kargu/async)

(require 'kargu/tools/registry)

(defvar kargu--tool-registry)

(cl-defstruct (kargu-permission-operation
               (:constructor kargu-permission--make-operation))
  "One approval's captured authority and single-use execution phase."
  (command nil :read-only t) (directory nil :read-only t)
  (risks nil :read-only t) (root nil :read-only t)
  (directories nil :read-only t) (origin nil :read-only t)
  (session nil :read-only t) (owner nil :read-only t)
  (environment nil :read-only t) (path nil :read-only t)
  (strict nil :read-only t) (validator nil :read-only t)
  (start nil :read-only t) (policy-revision nil :read-only t)
  task (phase :approval))

(defun kargu-permission--directory-identity (directory)
  "Return DIRECTORY's canonical name and filesystem identity, or signal."
  (let ((attributes (file-attributes directory)))
    (unless (eq t (car attributes))
      (user-error "Kargu: approval directory is no longer available"))
    (list (file-truename directory) (file-attribute-inode-number attributes)
          (file-attribute-device-number attributes))))

(defun kargu-permission--operation-valid-p (operation)
  "Return non-nil while OPERATION's captured authority is unchanged."
  (let ((origin (kargu-permission-operation-origin operation)))
    (and (buffer-live-p origin)
         (eq (kargu-permission-operation-owner operation) kargu--loop-run)
         (with-current-buffer origin
           (and (eq (kargu-permission-operation-session operation) (kargu-session-context))
                (equal (kargu-permission-operation-root operation)
                       (kargu-permission-project-root))
                (equal (kargu-permission-operation-environment operation) process-environment)
                (equal (kargu-permission-operation-path operation) exec-path)
                (eq (kargu-permission-operation-strict operation) kargu-permission-strict-mode)
                (equal (kargu-permission-operation-directories operation)
                       (mapcar #'kargu-permission--directory-identity
                               (list (kargu-permission-operation-root operation)
                                     (kargu-permission-operation-directory operation))))
                (or (null (kargu-permission-operation-policy-revision operation))
                    (and (boundp 'kargu--tool-registry)
                         (kargu-tool-registry-p kargu--tool-registry)
                         (eql (kargu-permission-operation-policy-revision operation)
                              (kargu-tool-registry-revision kargu--tool-registry))))
                (or (null (kargu-permission-operation-validator operation))
                    (funcall (kargu-permission-operation-validator operation))))))))

(defun kargu-permission--execute-decision (operation approved)
  "Consume APPROVED for OPERATION once, before starting any side effect."
  (kargu-contract-assert (lambda (value) (memq value '(nil t))) approved)
  (when (eq (kargu-permission-operation-phase operation) :approval)
    (setf (kargu-permission-operation-phase operation) :executing)
    (let ((task (kargu-permission-operation-task operation)))
      (if (not approved)
          (kargu-async-finish task nil "Command was not approved by the user")
        (funcall (kargu-permission-operation-start operation)
                 (kargu-async-wrap task
                                   (lambda (result)
                                     (kargu-contract-assert #'stringp result)
                                     (kargu-async-finish task result))))))))

(defun kargu-permission--request-operation (operation)
  "Acquire a cancellable presentation for OPERATION's prepared authority."
  (let* ((task (kargu-permission-operation-task operation))
         (handle (kargu-permission-request-approval-async
                  (kargu-permission-operation-command operation)
                  (kargu-permission-operation-directory operation)
                  (kargu-permission-operation-risks operation)
                  (kargu-async-wrap task
                                    (lambda (approved)
                                      (kargu-permission--execute-decision operation approved))))))
    (when handle
      (kargu-async-add-cleanup task (lambda () (kargu-cancel-confirmation handle))))))

(cl-defun kargu-permission-capture (command directory &key valid-p policy-revision risks start)
  "Capture COMMAND and DIRECTORY freshness for a later native approval.
VALID-P checks domain policy; POLICY-REVISION defaults to registry revision.
RISKS and START are optional legacy presenter data.
This snapshot grants no execution permission and presents no second prompt."
  (let* ((root (kargu-permission-project-root))
         (directory (file-name-as-directory (file-truename directory)))
         (_contained (kargu-permission-assert-within-project directory root "approval directory"))
         (revision (or policy-revision
                       (and (boundp 'kargu--tool-registry)
                            (kargu-tool-registry-p kargu--tool-registry)
                            (kargu-tool-registry-revision kargu--tool-registry)))))
    (kargu-permission--make-operation
     :command (copy-sequence command) :directory directory :root root
     :directories (mapcar #'kargu-permission--directory-identity (list root directory))
     :origin (current-buffer) :session (kargu-session-context)
     :owner kargu--loop-run :environment (mapcar #'copy-sequence process-environment)
     :path (mapcar (lambda (entry) (and entry (copy-sequence entry))) exec-path) :strict kargu-permission-strict-mode
     :validator valid-p :policy-revision revision :risks (mapcar #'copy-sequence risks) :start start)))

(cl-defun kargu-permission-execute (&key command directory risks start callback valid-p policy-revision)
  "Approve COMMAND in DIRECTORY with RISKS, then invoke START once.
START receives a result continuation.  CALLBACK receives its result string
or an ERROR description once.  VALID-P optionally checks domain freshness.
POLICY-REVISION optionally binds tool registry policy revision.
Return a task; cancellation or owner replacement suppresses stale effects."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p command)
  (kargu-contract-assert #'kargu-contract-non-empty-string-p directory)
  (kargu-contract-assert #'functionp start)
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert #'kargu-contract-callback-p valid-p)
  (kargu-contract-assert
   (lambda (value) (and (proper-list-p value) (cl-every #'stringp value))) risks)
  (let* ((operation (kargu-permission-capture command directory :valid-p valid-p
                                              :policy-revision policy-revision :risks risks :start start))
         (task (kargu-async-start
                (lambda (value error)
                  (funcall callback (if error (concat "ERROR: " error) value)))
                :valid-p (lambda () (kargu-permission--operation-valid-p operation)))))
    (setf (kargu-permission-operation-task operation) task)
    (funcall (kargu-async-wrap task (lambda () (kargu-permission--request-operation operation))))
    task))

(provide 'kargu/permission/execute)
;;; execute.el ends here
