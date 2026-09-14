;;; kargu/contract/types.el --- Contract type predicates -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Type predicates for contract boundary validation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/contract/constants)

(defun kargu-contract-mode-p (mode)
  "Return non-nil if MODE is one of `kargu-all-modes'."
  (and (symbolp mode) (memq mode kargu-all-modes)))

(defun kargu-contract-role-p (role)
  "Return non-nil if ROLE is a valid protocol role string."
  (and (stringp role)
       (member role (list kargu-role-system
                          kargu-role-user
                          kargu-role-assistant
                          kargu-role-tool))))

(defun kargu-contract-content-p (content)
  "Return non-nil if CONTENT is a valid message content field."
  (or (stringp content)
       (null content)
       (eq content :json-null)
       (eq content :json-false)
       (vectorp content)
       (listp content)))

(defun kargu-contract-tool-call-p (call)
  "Return non-nil if CALL is a structurally valid tool-call alist."
  (and (consp call)
       (let ((fn (alist-get "function" call nil nil #'equal)))
         (and (consp fn)
              (stringp (alist-get "name" fn nil nil #'equal))))))

(defun kargu-contract-tool-calls-p (calls)
  "Return non-nil if CALLS is nil, :json-null, or a collection of tool calls."
  (cond
   ((or (null calls) (eq calls :json-null)) t)
   ((vectorp calls)
    (cl-every #'kargu-contract-tool-call-p calls))
   ((listp calls)
    (cl-every #'kargu-contract-tool-call-p calls))
   (t nil)))

(defun kargu-contract-message-p (msg)
  "Return non-nil if MSG is a valid chat message alist."
  (and (consp msg)
       (let ((role (alist-get "role" msg nil nil #'equal))
             (content (alist-get "content" msg nil nil #'equal))
             (calls (alist-get "tool_calls" msg nil nil #'equal)))
         (and (kargu-contract-role-p role)
              (kargu-contract-content-p content)
              (kargu-contract-tool-calls-p calls)))))

(defun kargu-contract-history-p (history)
  "Return non-nil if HISTORY is a valid message sequence."
  (and (listp history)
       (or (null history)
           (and (kargu-contract-message-p (car history))
                (equal (alist-get "role" (car history) nil nil #'equal)
                       kargu-role-system)
                (cl-every #'kargu-contract-message-p history)))))

(defun kargu-contract-filepath-p (path)
  "Return non-nil if PATH is a non-empty string."
  (and (stringp path) (not (string-empty-p (string-trim path)))))

(defun kargu-contract-non-empty-string-p (str)
  "Return non-nil if STR is a non-empty string."
  (and (stringp str) (not (string-empty-p (string-trim str)))))

(defun kargu-contract-url-p (url)
  "Return non-nil if URL is a valid http or https URL string."
  (and (stringp url)
       (string-match-p "\\`https?://[^ \t\r\n]+" (string-trim url))))

(defun kargu-contract-tool-executor-p (fn)
  "Return non-nil if FN is a callable tool executor."
  (functionp fn))

(defun kargu-contract-prompt-p (prompt)
  "Return non-nil if PROMPT is a string or nil."
  (or (null prompt) (stringp prompt)))

(defun kargu-contract-callback-p (cb)
  "Return non-nil if CB is callable or nil."
  (or (null cb) (functionp cb)))

(defun kargu-contract-response-p (resp)
  "Return non-nil if RESP has a valid OpenAI response shape."
  (and (consp resp)
       (or (alist-get "choices" resp nil nil #'equal)
           (alist-get "error" resp nil nil #'equal))))

(defun kargu-contract-tool-schema-p (schema)
  "Return non-nil if SCHEMA is nil or a valid JSON schema alist.
A valid schema alist must have (\"type\" . \"object\") and a \"properties\" entry."
  (or (null schema)
      (and (consp schema)
           (cl-every #'consp schema)
           (let ((type (or (cdr (assoc "type" schema))
                           (cdr (assoc :type schema))))
                 (props-entry (or (assoc "properties" schema)
                                  (assoc :properties schema))))
             (and (stringp type)
                  (equal type "object")
                  props-entry
                  (let ((props (cdr props-entry)))
                    (or (null props)
                        (eq props :json-empty-object)
                        (and (consp props) (cl-every #'consp props)))))))))

(provide 'kargu/contract/types)

;;; kargu/contract/types.el ends here
