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

(defun kargu-bridge-plan--state (reply)
  "Return REPLY's plan lifecycle state as a keyword."
  (let ((state (and (hash-table-p reply) (gethash "state" reply))))
    (and (stringp state) (intern (format ":%s" state)))))

(defun kargu-bridge-plan--call (session method fields decode callback)
  "Send plan METHOD with FIELDS for SESSION; CALLBACK gets (DECODE-RESULT FAILURE).
FIELDS is a plist of wire keys and values added to the conversation scope."
  (kargu-bridge-conversation-with
   session
   (lambda (connection _application scope failure)
     (if failure
         (kargu-bridge--callback callback nil failure)
       (let ((params (kargu-bridge--object
                      "application_id" (gethash "application_id" scope)
                      "session_id" (gethash "session_id" scope))))
         (while fields (puthash (pop fields) (pop fields) params))
         (kargu-bridge-call
          connection method params
          (lambda (reply error-data)
            (if error-data
                (kargu-bridge--callback callback nil error-data)
              (kargu-bridge--callback callback (funcall decode reply) nil)))))))))

(defun kargu-bridge-plan-create (session text callback)
  "Create an implementation plan with TEXT for SESSION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (kargu-bridge-plan--call session "session/plan/create" (list "text" text)
                           #'kargu-bridge-plan--decode callback))

(defun kargu-bridge-plan-revise (session plan-id revision text callback)
  "Revise PLAN-ID's TEXT for SESSION from REVISION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (kargu-bridge-plan--call session "session/plan/revise"
                           (list "plan_id" plan-id "expected_revision" revision "text" text)
                           #'kargu-bridge-plan--decode callback))

(defun kargu-bridge-plan-claim (session plan-id revision hash callback)
  "Claim PLAN-ID with REVISION and HASH for SESSION; deliver to CALLBACK.
CALLBACK receives (PLAN FAILURE)."
  (kargu-bridge-plan--call session "session/plan/claim"
                           (list "plan_id" plan-id "expected_revision" revision
                                 "expected_hash" hash)
                           #'kargu-bridge-plan--decode callback))

(defun kargu-bridge-plan-complete (session plan-id success callback)
  "Complete claimed PLAN-ID for SESSION with SUCCESS flag; deliver to CALLBACK.
CALLBACK receives (STATE FAILURE)."
  (kargu-bridge-plan--call session "session/plan/complete"
                           (list "plan_id" plan-id "success" (if success t :json-false))
                           #'kargu-bridge-plan--state callback))

(defun kargu-bridge-plan-reject (session plan-id revision callback)
  "Reject pending PLAN-ID with REVISION for SESSION; deliver to CALLBACK.
CALLBACK receives (STATE FAILURE)."
  (kargu-bridge-plan--call session "session/plan/reject"
                           (list "plan_id" plan-id "expected_revision" revision)
                           #'kargu-bridge-plan--state callback))

(provide 'kargu/bridge/plan)

;;; plan.el ends here
