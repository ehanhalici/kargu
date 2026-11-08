;;; mode.el --- Native conversation mode commits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Commit validated mode transitions to the conversation's Rust actor from the
;; last acknowledged revision, and decode the native acknowledgement.
;; Rust owns the revision, tool availability, and debug admission;
;; a refused intent leaves the editor's committed view untouched.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/bridge/application)
(require 'kargu/bridge/conversation)
(require 'kargu/core/session)
(require 'kargu/application/coordinator)

(defun kargu-bridge-mode--decode (reply)
  "Return REPLY's revision and acknowledged mode as (REVISION . DTO)."
  (let* ((revision (and (hash-table-p reply) (gethash "revision" reply)))
         (mode-str (and (hash-table-p reply) (gethash "mode" reply)))
         (debug-ready (and (hash-table-p reply) (gethash "debug_ready" reply)))
         (tools (and (hash-table-p reply) (gethash "available_tools" reply))))
    (unless (and (natnump revision) (stringp mode-str))
      (error "Invalid native mode acknowledgement"))
    (cons revision
          (list :mode (intern mode-str)
                :debug-ready (and debug-ready t)
                :available-tools (if (vectorp tools) (append tools nil) tools)))))

(defun kargu-bridge-mode--binding (application session)
  "Return SESSION's conversation binding for APPLICATION."
  (gethash application (kargu-session-native-conversations session)))

(defun kargu-bridge-mode--status (failure)
  "Return FAILURE's native status string, if any."
  (let ((data (and (hash-table-p failure) (gethash "data" failure))))
    (and (hash-table-p data) (gethash "status" data))))

(defun kargu-bridge-mode--send (connection application session scope desired debug-ready callback)
  "Commit DESIRED for SESSION under conversation SCOPE, then call CALLBACK.
CONNECTION and APPLICATION are the captured lease of SCOPE."
  (let ((binding (kargu-bridge-mode--binding application session)))
    (kargu-bridge-call
     connection "session/mode/commit"
     (kargu-bridge--object
      "application_id" (gethash "application_id" scope)
      "session_id" (gethash "session_id" scope)
      "expected_revision" (or (and binding (kargu-bridge-conversation-mode-revision binding))
                              (kargu-session-mode-revision session))
      "mode" (symbol-name desired)
      "debug_ready" (if debug-ready t :json-false))
     (lambda (reply failure)
       (if failure
           (progn
             (when (equal (kargu-bridge-mode--status failure) "stale_revision")
               (kargu-bridge-call
                connection "session/mode" (kargu-bridge-application--copy-scope scope)
                (lambda (current error-data)
                  (unless error-data
                    (ignore-errors
                      (let ((decoded (kargu-bridge-mode--decode current)))
                        (when binding
                          (setf (kargu-bridge-conversation-mode-revision binding) (car decoded)))
                        (setf (kargu-session-mode-revision session) (car decoded))))))))
             (kargu-bridge--callback callback nil failure))
         (condition-case nil
             (let ((decoded (kargu-bridge-mode--decode reply)))
               (if (not (kargu-bridge-application-scope-equal-p
                         scope (kargu-bridge-conversation-current-scope application session connection)))
                   (kargu-bridge--callback callback nil (kargu-bridge--fault "owner_closed"))
                 (when binding
                   (setf (kargu-bridge-conversation-mode-revision binding) (car decoded)))
                 (setf (kargu-session-mode-revision session) (car decoded))
                 (setf (kargu-session-mode-value session) (plist-get (cdr decoded) :mode))
                 (setf (kargu-session-mode-tools session) (plist-get (cdr decoded) :available-tools))
                 (kargu-bridge--callback callback (cdr decoded) nil)))
           (error (kargu-bridge--callback callback nil (kargu-bridge--fault "protocol_error")))))))))

(defun kargu-bridge-mode-commit (session desired debug-ready callback)
  "Commit DESIRED mode for SESSION in Rust conversation; deliver CALLBACK once.
DEBUG-READY indicates whether debugger preparation succeeded.
CALLBACK receives (RESULT FAILURE) where RESULT is the native mode DTO."
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
              (kargu-bridge-mode--send
               connection app session scope desired debug-ready callback)))))))))

(provide 'kargu/bridge/mode)
;;; mode.el ends here
