;;; validate.el --- Validate session records before restoration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Validate and copy untrusted session records before touching chat state.
;; Protocol repair remains the native backend's responsibility, not storage's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/json)
(require 'kargu/contract/constants)
(require 'kargu/chat/session/storage)
(require 'kargu/chat/session/schema)

(defconst kargu-session-validate--max-depth 32
  "Maximum accepted session value nesting, including native record cells.")

(defconst kargu-session-validate--max-nodes 100000
  "Maximum number of values inspected before rejecting an in-memory record.")

(defun kargu-session-validate--tree (value depth budget)
  "Check VALUE within DEPTH and remaining mutable node BUDGET.
Reject circular/improper lists before the native record encoder sees them."
  (when (or (>= depth kargu-session-validate--max-depth)
            (< (cl-decf (car budget)) 0))
    (user-error "Kargu: session structure exceeds validation limits"))
  (when (and (stringp value)
             (< (cl-decf (cadr budget) (string-bytes value)) 0))
    (user-error "Kargu: session strings exceed the size limit"))
  (let ((visit (lambda (child)
                 (kargu-session-validate--tree child (1+ depth) budget))))
    (cond
     ((hash-table-p value)
      (maphash (lambda (key child) (funcall visit key) (funcall visit child)) value))
     ((vectorp value) (mapc visit value))
     ((consp value)
      (unless (proper-list-p value)
        (user-error "Kargu: session contains a circular or improper record"))
      (if (cl-every (lambda (cell) (and (consp cell) (stringp (car cell)))) value)
          (let ((keys (make-hash-table :test #'equal)))
            (dolist (cell value)
              (when (gethash (car cell) keys)
                (user-error "Kargu: duplicate session record key"))
              (puthash (car cell) t keys)
              (funcall visit (car cell))
              (funcall visit (cdr cell))))
        (mapc visit value))))))

(defun kargu-session-validate--optional (record key predicate)
  "Check RECORD's KEY with PREDICATE when present, without echoing values."
  (let ((value (gethash key record :kargu-missing)))
    (unless (or (eq value :kargu-missing) (funcall predicate value))
      (user-error "Kargu: invalid session field %s" key))))

(defun kargu-session-validate--object (value label)
  "Require VALUE to be a JSON object described by LABEL."
  (unless (hash-table-p value)
    (user-error "Kargu: invalid session %s; expected an object" label)))

(defun kargu-session-validate--nonempty-p (value)
  "Return non-nil when VALUE is a non-blank string."
  (and (stringp value) (not (string-empty-p (string-trim value)))))

(defun kargu-session-validate--call (call)
  "Check the native protocol tool CALL saved in an assistant message."
  (kargu-session-validate--object call "tool call")
  (let ((function (gethash "function" call)))
    (unless (and (kargu-session-validate--nonempty-p (gethash "id" call))
                 (equal (gethash "type" call) "function"))
      (user-error "Kargu: invalid session tool call identity"))
    (kargu-session-validate--object function "tool function")
    (unless (and (kargu-session-validate--nonempty-p (gethash "name" function))
                 (stringp (gethash "arguments" function)))
      (user-error "Kargu: invalid session tool function"))))

(defun kargu-session-validate--content-p (value)
  "Return non-nil for native text, null/false or typed content blocks VALUE.
Preserve unknown block kinds for backend adapters rather than dropping them."
  (or (stringp value) (memq value '(:json-null :json-false))
      (and (vectorp value)
           (cl-every
            (lambda (block)
              (and (hash-table-p block)
                   (kargu-session-validate--nonempty-p (gethash "type" block))
                   (or (not (equal (gethash "type" block) "text"))
                       (stringp (gethash "text" block)))))
            value))))

(defun kargu-session-validate--message (message)
  "Check the native protocol MESSAGE without repairing its conversation."
  (kargu-session-validate--object message "message")
  (unless (member (gethash "role" message) '("system" "user" "assistant" "tool"))
    (user-error "Kargu: invalid session message role"))
  (kargu-session-validate--optional message "content" #'kargu-session-validate--content-p)
  (dolist (key '("name" "tool_call_id" "reasoning_content"))
    (kargu-session-validate--optional message key #'stringp))
  (when (equal (gethash "role" message) "tool")
    (unless (kargu-session-validate--nonempty-p (gethash "tool_call_id" message))
      (user-error "Kargu: session tool result is missing its call ID")))
  (let ((calls (gethash "tool_calls" message)))
    (unless (or (null calls) (eq calls :json-null) (vectorp calls))
      (user-error "Kargu: invalid session tool calls; expected an array"))
    (when (vectorp calls) (mapc #'kargu-session-validate--call calls))))

(defun kargu-session-validate--fields (record)
  "Check top-level metadata and native messages in typed JSON RECORD."
  (kargu-session-validate--object record "record")
  (unless (kargu-session-validate--nonempty-p (gethash "id" record))
    (user-error "Kargu: session is missing its identifier"))
  (dolist (key '("title" "transcript" "provider" "model" "project_root"
                 "project_name" "created_at" "updated_at"))
    (kargu-session-validate--optional record key #'stringp))
  (dolist (key '("requests" "tokens_in" "tokens_out"))
    (kargu-session-validate--optional record key #'natnump))
  (kargu-session-validate--optional
   record "mode" (lambda (mode) (member mode (mapcar #'symbol-name kargu-all-modes))))
  (kargu-session-validate--optional record "messages" #'vectorp)
  (mapc #'kargu-session-validate--message (gethash "messages" record)))

(defun kargu-session-validate (data)
  "Validate session DATA and return a detached typed JSON record.
Reject malformed fields, excessive size/depth and non-JSON extensions before
any chat buffer, history, counters or selection is changed."
  (kargu-session-validate--tree data 0 (list kargu-session-validate--max-nodes
                                           kargu-session-max-file-bytes))
  (let* ((text (condition-case nil (kargu-json-encode-record data)
                 (error (user-error "Kargu: session contains unsupported JSON values")))))
    (when (> (string-bytes (encode-coding-string text 'utf-8)) kargu-session-max-file-bytes)
      (user-error "Kargu: session data exceeds kargu-session-max-file-bytes"))
    (let ((record (kargu-session-migrate (kargu-json-decode text))))
      (kargu-session-validate--fields record)
      record)))

(provide 'kargu/chat/session/validate)
;;; validate.el ends here
