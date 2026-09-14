;;; kargu/history/protocol.el --- Protocol message history queue -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Message store and role helpers matching the OpenAI protocol specification.

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

(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/prompt)

(declare-function kargu-api-cancel "kargu/api/client" ())

(defvar kargu--message-history nil
  "Conversation history, oldest first.
Each element is an alist with string keys in the OpenAI
chat-completions shape: (\"role\" . \"system\"|\"user\"|\"assistant\"|\"tool\").")

(defvar kargu--compaction-system)

(defun kargu--history-add (role content &rest fields)
  "Append a message ((ROLE . CONTENT) . FIELDS) to the history.
Return the new message alist."
  (kargu-contract-assert #'kargu-contract-role-p role
                         "Invalid message role %S (expected one of '(\"system\" \"user\" \"assistant\" \"tool\"))"
                         role)
  (kargu-contract-assert #'kargu-contract-content-p content
                         "Invalid message content %S (must be string, nil, or JSON null)"
                         content)
  (let ((msg (append `(("role" . ,role) ("content" . ,content)) fields)))
    (setq kargu--message-history
          (append kargu--message-history (list msg)))
    msg))

(defalias 'kargu-history-add #'kargu--history-add)

(defun kargu--history-add-tool-result (tool-call-id name output)
  "Append a tool result message answering TOOL-CALL-ID.
NAME is the tool name, OUTPUT the result string."
  (kargu-log 'debug "tool result %s (%s): %d chars"
             tool-call-id name (length output))
  (kargu--history-add "tool" output
                      `("tool_call_id" . ,tool-call-id)
                      `("name" . ,name)))

(defalias 'kargu-history-add-tool-result #'kargu--history-add-tool-result)

(defun kargu-history-reset ()
  "Clear the conversation history and cancel in-flight requests."
  (interactive)
  (when (fboundp 'kargu-api-cancel)
    (kargu-api-cancel))
  (setq kargu--message-history nil)
  (setq kargu--compaction-system nil)
  (kargu-prompt-clear-cache)
  (kargu-log 'info "history cleared")
  (when (called-interactively-p 'any)
    (message "kargu history cleared")))

(defun kargu--history-last-role ()
  "Role of the last history message, or nil when empty."
  (when kargu--message-history
    (kargu--aget (car (last kargu--message-history)) "role")))

(defun kargu--role-name (role)
  "Canonical string name of ROLE (string or symbol), or nil."
  (cond
   ((null role) nil)
   ((stringp role) role)
   ((symbolp role) (symbol-name role))
   (t (format "%s" role))))

(defun kargu--assistant-role-p (role)
  "Non-nil if ROLE is an assistant turn."
  (let ((name (kargu--role-name role)))
    (or (equal name "assistant")
        (equal name "model"))))

(defun kargu--normalize-assistant-role (msg)
  "Rewrite Gemini `model' ROLE on MSG to OpenAI `assistant'.
Mutates MSG and returns it."
  (let ((cell (assoc "role" msg)))
    (cond
     ((null cell)
      (push '("role" . "assistant") msg))
     ((kargu--assistant-role-p (cdr cell))
      (setcdr cell "assistant"))))
  msg)

(defun kargu--calls-to-list (calls)
  "Convert CALLS to a list of tool-call alists, or nil if empty."
  (cond
   ((null calls) nil)
   ((eq calls :json-null) nil)
   ((vectorp calls)
    (if (= (length calls) 0) nil (append calls nil)))
   ((listp calls) (if (null calls) nil calls))
   (t nil)))

(defun kargu--empty-assistant-tail-p ()
  "Non-nil when the history ends on a tool-less assistant turn."
  (let ((last (car (last kargu--message-history))))
    (and last
         (kargu--assistant-role-p (kargu--aget last "role"))
         (null (kargu--calls-to-list (kargu--aget last "tool_calls"))))))

(defalias 'kargu--history-completed-assistant-tail-p #'kargu--empty-assistant-tail-p)
(defalias 'kargu-history-empty-tail-p #'kargu--empty-assistant-tail-p)

(defun kargu--clean-assistant-message (msg)
  "Return a normalized copy of assistant message MSG."
  (let ((content (kargu--aget msg "content"))
        (calls (kargu--calls-to-list (kargu--aget msg "tool_calls"))))
    (let ((cleaned (if (and calls
                            (or (null content)
                                (eq content :json-null)
                                (equal content "")))
                       (cl-remove-if (lambda (cell) (equal (car cell) "content")) msg)
                     msg)))
      (if (and calls (vectorp (kargu--aget cleaned "tool_calls")))
          (cons `("tool_calls" . ,calls)
                (cl-remove-if (lambda (cell) (equal (car cell) "tool_calls")) cleaned))
        cleaned))))

(defun kargu-history-inspect ()
  "Dump the protocol view of the history to the log buffer."
  (interactive)
  (kargu-log 'info "--- history begin (%d messages) ---"
             (length kargu--message-history))
  (let ((i 0))
    (dolist (msg kargu--message-history)
      (setq i (1+ i))
      (let ((role (kargu--aget msg "role"))
            (text (or (kargu--aget msg "content") ""))
            (calls (kargu--calls-to-list (kargu--aget msg "tool_calls")))
            (id (kargu--aget msg "tool_call_id")))
        (kargu-log 'info "[%2d] %-9s %s%s%s" i role
                   (truncate-string-to-width
                    (replace-regexp-in-string "\n" " " text) 70)
                   (if id (format " tool_call_id=%s" id) "")
                   (if calls
                       (format " tool_calls=%d" (length calls))
                     "")))))
  (kargu-log 'info "--- history end ---")
  (kargu-show-log))

(provide 'kargu/history/protocol)

;;; kargu/history/protocol.el ends here
