;;; plan.el --- Native conversation implementation plan bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bridge interface to the native implementation plan actor.
;; Plans are owned by a conversation and track unique artifact ID, revision,
;; SHA-256 content hash, and lifecycle states (pending, dispatching, rejected,
;; superseded, terminal).  Approvals are single-use and fail closed.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/bridge/application)
(require 'kargu/bridge/conversation)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)

(defun kargu-bridge-plan--decode (reply)
  "Decode REPLY containing a native plan record into a plist."
  (when (hash-table-p reply)
    (let* ((plan (gethash "plan" reply reply))
           (id (and (hash-table-p plan) (gethash "id" plan)))
           (rev (and (hash-table-p plan) (gethash "revision" plan)))
           (hash (and (hash-table-p plan) (gethash "content_hash" plan)))
           (state (and (hash-table-p plan) (gethash "state" plan)))
           (text (and (hash-table-p plan) (gethash "text" plan))))
      (when (and (stringp id) (natnump rev))
        (list :id id
              :revision rev
              :content-hash hash
              :state (and (stringp state) (intern (format ":%s" state)))
              :text text)))))

(defun kargu-bridge-plan-create (session text callback)
  "Create an implementation plan with TEXT for SESSION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (kargu-bridge-call
               connection "session/plan/create"
               (kargu-bridge--object
                "application_id" (gethash "application_id" scope)
                "session_id" (gethash "session_id" scope)
                "text" text)
               (lambda (reply error-data)
                 (if error-data
                     (kargu-bridge--callback callback nil error-data)
                   (kargu-bridge--callback callback (kargu-bridge-plan--decode reply) nil))))))))))))

(defun kargu-bridge-plan-revise (session plan-id revision text callback)
  "Revise PLAN-ID's TEXT for SESSION from REVISION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (kargu-bridge-call
               connection "session/plan/revise"
               (kargu-bridge--object
                "application_id" (gethash "application_id" scope)
                "session_id" (gethash "session_id" scope)
                "plan_id" plan-id
                "expected_revision" revision
                "text" text)
               (lambda (reply error-data)
                 (if error-data
                     (kargu-bridge--callback callback nil error-data)
                   (kargu-bridge--callback callback (kargu-bridge-plan--decode reply) nil))))))))))))

(defun kargu-bridge-plan-claim (session plan-id revision hash callback)
  "Claim PLAN-ID with REVISION and HASH for SESSION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (kargu-bridge-call
               connection "session/plan/claim"
               (kargu-bridge--object
                "application_id" (gethash "application_id" scope)
                "session_id" (gethash "session_id" scope)
                "plan_id" plan-id
                "expected_revision" revision
                "expected_hash" hash)
               (lambda (reply error-data)
                 (if error-data
                     (kargu-bridge--callback callback nil error-data)
                   (kargu-bridge--callback callback (kargu-bridge-plan--decode reply) nil))))))))))))

(defun kargu-bridge-plan-complete (session plan-id success callback)
  "Complete claimed PLAN-ID for SESSION with SUCCESS flag; deliver to CALLBACK.
CALLBACK receives (STATE FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (kargu-bridge-call
               connection "session/plan/complete"
               (kargu-bridge--object
                "application_id" (gethash "application_id" scope)
                "session_id" (gethash "session_id" scope)
                "plan_id" plan-id
                "success" (if success t :json-false))
               (lambda (reply error-data)
                 (if error-data
                     (kargu-bridge--callback callback nil error-data)
                   (let ((state (and (hash-table-p reply) (gethash "state" reply))))
                     (kargu-bridge--callback
                      callback (and (stringp state) (intern (format ":%s" state))) nil)))))))))))))

(defun kargu-bridge-plan-reject (session plan-id revision callback)
  "Reject pending PLAN-ID with REVISION for SESSION; deliver to CALLBACK.
CALLBACK receives (STATE FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (kargu-bridge-call
               connection "session/plan/reject"
               (kargu-bridge--object
                "application_id" (gethash "application_id" scope)
                "session_id" (gethash "session_id" scope)
                "plan_id" plan-id
                "expected_revision" revision)
               (lambda (reply error-data)
                 (if error-data
                     (kargu-bridge--callback callback nil error-data)
                   (let ((state (and (hash-table-p reply) (gethash "state" reply))))
                     (kargu-bridge--callback
                      callback (and (stringp state) (intern (format ":%s" state))) nil)))))))))))))

(defun kargu-bridge-plan-query (session callback &optional plan-id)
  "Read SESSION's current plan (or optional PLAN-ID); deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (let ((origin (current-buffer)))
    (kargu-bridge-application-ensure
     (lambda (connection app failure)
       (if failure
           (kargu-bridge--callback callback nil failure)
         (kargu-bridge-conversation-ensure
          connection app session origin
          (lambda (scope failure)
            (if failure
                (kargu-bridge--callback callback nil failure)
              (let ((params (kargu-bridge--object
                             "application_id" (gethash "application_id" scope)
                             "session_id" (gethash "session_id" scope))))
                (when plan-id
                  (puthash "plan_id" plan-id params))
                (kargu-bridge-call
                 connection "session/plan" params
                 (lambda (reply error-data)
                   (if error-data
                       (kargu-bridge--callback callback nil error-data)
                     (kargu-bridge--callback callback (kargu-bridge-plan--decode reply) nil)))))))))))))

(provide 'kargu/bridge/plan)

;;; plan.el ends here
