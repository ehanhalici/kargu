;;; session.el --- Native Rust agent session lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides high-level ports to the native Rust agent session machine:
;; - `kargu-bridge-session-start`: starts native agent turn via `session/prompt`
;; - `kargu-bridge-session-snapshot`: queries native session state and history revision via `session/snapshot`

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/bridge)
(require 'kargu/bridge/application)
(require 'kargu/bridge/conversation)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)

(defun kargu-bridge-session--same-scope-p (left right)
  "Compare exact native run scopes LEFT and RIGHT without sharing objects."
  (and (hash-table-p left) (hash-table-p right)
       (= (hash-table-count left) 8) (= (hash-table-count right) 8)
       (cl-every (lambda (key) (equal (gethash key left :missing)
                                     (gethash key right :missing)))
                 '("purpose" "application_id" "session_id" "run_id" "claim_id"
                   "generation" "config_revision" "policy_revision"))))

(defun kargu-bridge-session-owned-entry (connection params)
  "Return the live native waiter owning PARAMS on exact CONNECTION."
  (when (and (eq (kargu-bridge-status connection) 'ready)
             (hash-table-p params)
             (equal (gethash "connection_epoch" params)
                    (kargu-bridge-connection-epoch connection)))
    (let* ((id (gethash "request_id" params))
           (entry (gethash id (kargu-bridge-connection-pending connection)))
           (intent (and entry (kargu-bridge--pending-session-intent entry)))
           (scope (gethash "scope" params))
           (expected (and intent (gethash "scope" intent)))
           (owner (and entry (kargu-bridge--pending-owner entry)))
           (captured (and entry (kargu-bridge--pending-session-run-scope entry))))
      (when (and intent (hash-table-p scope) (hash-table-p expected)
                 (= (hash-table-count scope) 8)
                 (equal (gethash "purpose" scope) "agent_turn")
                 (or (null owner) (buffer-live-p owner))
                 (or (null (kargu-bridge--pending-deadline entry))
                     (< (float-time) (kargu-bridge--pending-deadline entry)))
                 (cl-every (lambda (key) (equal (gethash key expected)
                                               (gethash key scope)))
                           '("application_id" "session_id"))
                 (cl-every (lambda (key) (equal (gethash key intent)
                                               (gethash key scope)))
                           '("config_revision" "policy_revision"))
                 (or (null captured)
                     (kargu-bridge-session--same-scope-p captured scope)))
        (unless captured
          (setf (kargu-bridge--pending-session-run-scope entry)
                (kargu-bridge--decode (json-serialize scope))))
        entry))))

(defun kargu-bridge-session-notify (connection method params)
  "Deliver scoped, sequenced native METHOD/PARAMS on CONNECTION."
  (when-let* ((entry (kargu-bridge-session-owned-entry connection params)))
    (let* ((intent (kargu-bridge--pending-session-intent entry))
           (scope (gethash "scope" intent))
           (key (cons (gethash "application_id" scope) (gethash "session_id" scope)))
           (table (kargu-bridge-connection-session-sequences connection))
           (previous (or (kargu-bridge--pending-session-sequence entry) (gethash key table)))
           (sequence (gethash "sequence" params))
           (consumer (kargu-bridge--pending-on-event entry))
           (delta (kargu-bridge--pending-on-delta entry))
           (event (gethash "event" params))
           (forward (gethash "request_id" params)))
      (when (and (integerp sequence) (> sequence 0)
                 (or (null previous) (> sequence previous)))
        (when (and (not (gethash key table))
                   (>= (hash-table-count table) kargu-bridge--max-pending))
          (remhash (car (hash-table-keys table)) table))
        (puthash key sequence table)
        (setf (kargu-bridge--pending-session-sequence entry) sequence)
        (condition-case nil
            (progn
              (when (and previous (> sequence (1+ previous)))
                (when consumer
                  (funcall consumer "session/gap"
                           (kargu-bridge--object "previous" previous "sequence" sequence)))
                (kargu-bridge-session-snapshot
                 connection scope
                 (lambda (snapshot failure)
                   (when (and (not failure) consumer
                              (eq entry (gethash forward (kargu-bridge-connection-pending connection))))
                     (funcall consumer "session/snapshot" snapshot)))
                 (kargu-bridge--pending-owner entry)))
              (when (and (equal method "session/chunk") delta
                         (eq entry (kargu-bridge-session-owned-entry connection params)))
                (funcall delta (and (hash-table-p event) (gethash "delta" event))))
              (when (and consumer (eq entry (kargu-bridge-session-owned-entry connection params)))
                (funcall consumer method event)))
          ((error quit) (kargu-bridge--cancel connection forward "consumer_failed")))))))

(cl-defun kargu-bridge-session-start (connection scope arguments callback
                                                &key owner on-delta on-event)
  "Start a native agent run on CONNECTION for SCOPE with ARGUMENTS.
OWNER is the optional live source buffer of the call.  DELIVERIES go to
ON-DELTA and ON-EVENT; terminal result to CALLBACK."
  (kargu-bridge-call connection "session/prompt"
                     (kargu-bridge--object
                      "scope" scope
                      "arguments" arguments)
                     callback
                     :timeout :unlimited
                     :owner owner
                     :on-delta on-delta
                     :on-event on-event))

(defun kargu-bridge-session-snapshot (connection scope callback &optional owner)
  "Query session state snapshot for SCOPE on CONNECTION."
  (kargu-bridge-call connection "session/snapshot" scope callback :owner owner))

(defun kargu-bridge-session-save (connection params callback &optional owner)
  "Save session PARAMS atomically through CONNECTION.
The native persistence service owns the write."
  (kargu-bridge-call connection "session/save" params callback :owner owner))

(defun kargu-bridge-session-load (connection params callback &optional owner)
  "Load and recover session PARAMS via native persistence on CONNECTION."
  (kargu-bridge-call connection "session/load" params callback :owner owner))

(defun kargu-bridge-session-list (connection params callback &optional owner)
  "List session metadata for PARAMS via native persistence on CONNECTION."
  (kargu-bridge-call connection "session/list" params callback :owner owner))

(defun kargu-bridge-session-delete (connection params callback &optional owner)
  "Delete persisted session PARAMS via native persistence on CONNECTION."
  (kargu-bridge-call connection "session/delete" params callback :owner owner))

(defun kargu-bridge-session-import (connection params callback &optional owner)
  "Import legacy or local session PARAMS via native persistence on CONNECTION."
  (kargu-bridge-call connection "session/import" params callback :owner owner))

(defun kargu-bridge-session-scope (buffer callback)
  "Deliver (CONNECTION SCOPE FAILURE) for BUFFER to CALLBACK."
  (let ((buf (or buffer (current-buffer))))
    (if (not (buffer-live-p buf))
        (funcall callback nil nil (kargu-bridge--fault "owner_closed"))
      (let ((session (with-current-buffer buf (kargu-session-context buf)))
            (application (kargu-application-context)))
        (kargu-bridge-ensure
         (lambda (connection failure)
           (if failure
               (funcall callback nil nil failure)
             (kargu-bridge-application-ensure
              connection application
              (lambda (service failure)
                (if failure
                    (funcall callback nil nil failure)
                  (with-current-buffer buf
                    (kargu-bridge-conversation-ensure
                     connection application session service
                     (lambda (scope failure)
                       (if failure
                           (funcall callback nil nil failure)
                         (funcall callback connection scope nil)))))))))))))))

(provide 'kargu/bridge/session)
;;; session.el ends here
