;;; selection.el --- Native conversation selection commits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Encode one complete desired selection, commit it to the chat's Rust
;; conversation from the last acknowledged revision, and decode the native
;; acknowledgement.  Rust owns the revision, busy admission and validation;
;; a refused intent leaves the editor's committed view untouched.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/bridge/application)
(require 'kargu/bridge/conversation)
(require 'kargu/contract/selection)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)

(defun kargu-bridge-selection--encode (selection)
  "Return SELECTION as the native wire object."
  (let ((effort (kargu-selection-effort-value selection)))
    (kargu-bridge--object
     "provider" (or (kargu-selection-provider-value selection) :json-null)
     "model" (or (kargu-selection-model-value selection) :json-null)
     "effort" (cond ((eq effort kargu-selection-default-effort)
                     (kargu-bridge--object "kind" "inherit"))
                    ((null effort) (kargu-bridge--object "kind" "off"))
                    (t (kargu-bridge--object "kind" "named" "name" (symbol-name effort)))))))

(defun kargu-bridge-selection--text (value)
  "Return VALUE when it is a wire string, nil for JSON null, or signal."
  (cond ((eq value :json-null) nil)
        ((and (stringp value) (not (string-empty-p value))) value)
        (t (error "Invalid native selection field"))))

(defun kargu-bridge-selection--decode (reply)
  "Return REPLY's revision and acknowledged selection as (REVISION . VALUE)."
  (let* ((revision (and (hash-table-p reply) (gethash "revision" reply)))
         (selection (and (hash-table-p reply) (gethash "selection" reply)))
         (effort (and (hash-table-p selection) (gethash "effort" selection)))
         (kind (and (hash-table-p effort) (gethash "kind" effort))))
    (unless (and (natnump revision) (hash-table-p selection) (stringp kind))
      (error "Invalid native selection acknowledgement"))
    (cons revision
          (kargu-selection-create
           :provider (kargu-bridge-selection--text (gethash "provider" selection :json-null))
           :model (kargu-bridge-selection--text (gethash "model" selection :json-null))
           :effort (pcase kind
                     ("inherit" kargu-selection-default-effort)
                     ("off" nil)
                     ("named" (intern (kargu-bridge-selection--text (gethash "name" effort))))
                     (_ (error "Invalid native effort kind")))))))

(defun kargu-bridge-selection--binding (application session)
  "Return SESSION's conversation binding for APPLICATION."
  (gethash application (kargu-session-native-conversations session)))

(defun kargu-bridge-selection--status (failure)
  "Return FAILURE's native status string, if any."
  (let ((data (and (hash-table-p failure) (gethash "data" failure))))
    (and (hash-table-p data) (gethash "status" data))))

(defun kargu-bridge-selection--send (connection application session scope desired callback)
  "Commit DESIRED for SESSION under conversation SCOPE, then call CALLBACK.
CONNECTION and APPLICATION are the captured lease of SCOPE."
  (let ((binding (kargu-bridge-selection--binding application session)))
    (kargu-bridge-call
     connection "session/selection/commit"
     (kargu-bridge--object
      "application_id" (gethash "application_id" scope)
      "session_id" (gethash "session_id" scope)
      "expected_revision" (kargu-bridge-conversation-selection-revision binding)
      "selection" (kargu-bridge-selection--encode desired))
     (lambda (reply failure)
       (if failure
           (progn
             ;; A stale revision is refreshed for the next intent, never replayed.
             (when (equal (kargu-bridge-selection--status failure) "stale_revision")
               (kargu-bridge-call
                connection "session/selection" (kargu-bridge-application--copy-scope scope)
                (lambda (current error-data)
                  (unless error-data
                    (ignore-errors
                      (setf (kargu-bridge-conversation-selection-revision binding)
                            (car (kargu-bridge-selection--decode current))))))))
             (kargu-bridge--callback callback nil failure))
         (condition-case nil
             (let ((decoded (kargu-bridge-selection--decode reply)))
               (if (not (kargu-bridge-application-scope-equal-p
                         scope (kargu-bridge-conversation-current-scope application session connection)))
                   (kargu-bridge--callback callback nil (kargu-bridge--fault "owner_closed"))
                 (setf (kargu-bridge-conversation-selection-revision binding) (car decoded))
                 (kargu-bridge--callback callback (cdr decoded) nil)))
           (error (kargu-bridge--callback callback nil (kargu-bridge--fault "protocol_error")))))))))

(defun kargu-bridge-selection-commit (session desired callback)
  "Commit DESIRED for SESSION in its Rust conversation; deliver CALLBACK once.
CALLBACK receives (SELECTION FAILURE) where SELECTION is the native
acknowledgement.  The current buffer owns the conversation lease."
  (kargu-bridge-conversation-with
   session
   (lambda (connection application scope failure)
     (if failure
         (kargu-bridge--callback callback nil failure)
       (kargu-bridge-selection--send
        connection application session scope desired callback)))))

(provide 'kargu/bridge/selection)
;;; selection.el ends here
