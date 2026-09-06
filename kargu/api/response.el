;;; kargu/api/response.el --- Chat-completions response accessors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Read text, tool_calls, finish_reason, overflow from a decoded response.  Also stores the assistant turn in history.
;; Requires: `kargu/core', `kargu/json', `kargu/history'.

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
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)

;;;; Accessors ---------------------------------------------------

(defun kargu--response-choice (response)
  "Return the first choice alist of RESPONSE, or nil."
  (let ((choices (kargu--aget response "choices")))
    (cond
     ((consp choices) (car choices))
     ((vectorp choices) (and (> (length choices) 0) (aref choices 0)))
     (t nil))))

(defun kargu--response-message (response)
  "Return the message alist of RESPONSE's first choice, or nil."
  (let ((choice (kargu--response-choice response)))
    (and choice (kargu--aget choice "message"))))

(defun kargu-response-text (response)
  "Return the user-visible assistant `content' of RESPONSE, or nil.
Reasoning fields are ignored."
  (kargu--content-text (kargu--response-message response)))

(defun kargu-response-tool-calls (response)
  "Return the tool-call alists of RESPONSE, or nil.
A legacy OpenAI `function_call' object is wrapped as one call."
  (let ((message (kargu--response-message response)))
    (or (and message (kargu--aget message "tool_calls"))
        (let ((legacy (and message (kargu--aget message "function_call"))))
          (when (and legacy (kargu--object-p legacy))
            `((("id" . "call_legacy")
               ("type" . "function")
               ("function" . ,legacy))))))))

(defun kargu-response-finish-reason (response)
  "Return the finish_reason of RESPONSE's first choice, or nil."
  (let ((choice (kargu--response-choice response)))
    (and choice (kargu--aget choice "finish_reason"))))

(defun kargu-response-error-message (response)
  "Return the error message inside RESPONSE, or nil.
RESPONSE may be a decoded OpenRouter error body or one of the
synthetic error alists produced by this module.  Nested
`error.message' and `error.metadata' fields are flattened."
  (when-let* ((err (kargu--aget response "error")))
    (cond
     ((stringp err) err)
     ((kargu--object-p err)
      (or (kargu--provider-error-text `(("error" . ,err)))
          (kargu--aget err "message")
          (format "%S" err)))
     (t (format "%S" err)))))

(defun kargu-response-answer-text (response)
  "Assistant `content' of RESPONSE, ignoring reasoning fields."
  (kargu--content-text (kargu--response-message response)))

(defun kargu-response-reasoning-text (response)
  "Assistant reasoning or thought text of RESPONSE, or nil."
  (when-let* ((msg (kargu--response-message response)))
    (kargu--reasoning-text msg)))

(defun kargu--assistant-has-tool-calls-p (msg)
  "Non-nil when MSG carries a non-empty tool_calls array."
  (let ((calls (and msg (kargu--aget msg "tool_calls"))))
    (cond
     ((null calls) nil)
     ((eq calls :json-null) nil)
     ((vectorp calls) (> (length calls) 0))
     ((listp calls) (not (null calls)))
     (t nil))))

(defun kargu--overflow-message-p (msg)
  "Non-nil when MSG looks like a context-length / overflow error."
  (and (stringp msg)
       (let ((s (downcase msg)))
         (or (string-match-p "context.length" s)
             (string-match-p "context_length" s)
             (string-match-p "maximum context" s)
             (string-match-p "prompt is too long" s)
             (string-match-p "too many tokens" s)
             (string-match-p "max.*tokens.*exceed" s)
             (string-match-p "exceeds? the context" s)
             (string-match-p "token limit" s)))))

(defun kargu-response-overflow-p (response)
  "Non-nil when RESPONSE is a context-window overflow error."
  (or (kargu--aget response "overflow")
      (kargu--overflow-message-p (kargu-response-error-message response))))

(defun kargu--api-error-alist (msg)
  "Build a callback error alist from MSG, marking overflow when detected."
  (let ((err `(("error" . (("message" . ,msg))))))
    (when (kargu--overflow-message-p msg)
      (setq err (nconc err `(("overflow" . t)))))
    err))

(defun kargu--log-assistant-wire (response)
  "Wire-dump reconstructed assistant fields of RESPONSE."
  (when kargu-log-wire
    (let* ((choice (kargu--response-choice response))
           (msg (kargu--response-message response))
           (finish (and choice (kargu--aget choice "finish_reason")))
           (content (or (kargu--content-text msg) ""))
           (reason (or (kargu--reasoning-text msg) ""))
           (raw-calls (and msg (kargu--aget msg "tool_calls")))
           (calls (cond
                   ((vectorp raw-calls) (append raw-calls nil))
                   ((and raw-calls (listp raw-calls)) raw-calls)
                   (t (kargu-response-tool-calls response))))
           (parts (list (format "finish_reason: %s" finish)
                        (format "content (%d chars):\n%s"
                                (length content) content)
                        (format "reasoning_content (%d chars):\n%s"
                                (length reason) reason)))
           (i 0))
      (dolist (call (or calls ()))
        (let* ((fn (and (kargu--object-p call)
                        (kargu--aget call "function")))
               (name (or (and fn (kargu--aget fn "name")) "?"))
               (args (and fn (kargu--aget fn "arguments")))
               (arg-s (cond
                       ((stringp args) args)
                       ((null args) "")
                       (t (format "%S" args)))))
          (setq parts
                (append parts
                        (list (format "tool_calls[%d] %s arguments (%d chars):\n%s"
                                      i name (length arg-s) arg-s))))
          (setq i (1+ i))))
      (kargu--log-block "reconstructed assistant"
                        (mapconcat #'identity parts "\n\n")))))

(defun kargu--history-sanitize-tool-calls (msg)
  "Rewrite each tool call's `arguments' to a valid JSON object string."
  (let ((calls (and msg (kargu--aget msg "tool_calls"))))
    (dolist (call (cond
                   ((vectorp calls) (append calls nil))
                   ((listp calls) calls)
                   (t nil)))
      (when-let* ((fn (and (kargu--object-p call)
                           (kargu--aget call "function")))
                  (cell (and fn (assoc "arguments" fn))))
        (setcdr cell (kargu--encode-tool-arguments (cdr cell)))))))

(defun kargu--history-append-assistant (response)
  "Append RESPONSE's assistant message to the history; return it.
The message is deep-copied so later history repairs can never
corrupt the payload.  Gemini `model' roles are rewritten to
`assistant'.  `content' is normalized to a string so the next
request never resends a multipart list.  Reasoning is stored in
`reasoning_content' and is never copied into `content'.
A turn with no content, no reasoning and no tool_calls is skipped
so a fake empty assistant cannot poison the next POST."
  (when-let* ((message (kargu--response-message response)))
    (let* ((msg (kargu--normalize-assistant-role (copy-tree message)))
           (calls-p (kargu--assistant-has-tool-calls-p msg))
           (content (kargu--content-text message))
           (reason (kargu--reasoning-text message))
           (cell (assoc "content" msg)))
      (cond
       ((kargu--nonempty content)
        (if cell
            (setcdr cell content)
          (push `("content" . ,content) msg)))
       (calls-p
        (setq msg (cl-remove-if (lambda (c) (equal (car c) "content"))
                                msg)))
       (t
        (if cell
            (setcdr cell "")
          (push '("content" . "") msg))))
      (dolist (key '("reasoning" "reasoning_details" "thinking" "thought"))
        (setq msg (cl-remove-if (lambda (c) (equal (car c) key)) msg)))
      (let ((rc (assoc "reasoning_content" msg)))
        (cond
         ((kargu--nonempty reason)
          (if rc
              (setcdr rc reason)
            (push `("reasoning_content" . ,reason) msg)))
         (rc
          (setq msg (cl-remove-if (lambda (c) (equal (car c) "reasoning_content"))
                                  msg)))))
      (kargu--history-sanitize-tool-calls msg)
      (setq calls-p (kargu--assistant-has-tool-calls-p msg))
      (cond
       ((and (not (kargu--nonempty content))
             (not calls-p)
             (not (kargu--nonempty reason)))
        (kargu-log 'debug "skipping empty assistant turn")
        nil)
       (t
        (unless content
          (kargu-log 'debug "assistant content empty (type=%s, tools=%s)"
                           (type-of (kargu--aget message "content"))
                           (and calls-p t)))
        (setq kargu--message-history
              (append kargu--message-history (list msg)))
        (kargu--log-assistant-wire response)
        (kargu-log 'response "assistant turn stored: %d chars text, %s tool call(s)"
                         (length (or content ""))
                         (length (or (kargu--aget msg "tool_calls") ())))
        msg)))))

(defalias 'kargu-api-store-assistant-turn #'kargu--history-append-assistant)

(provide 'kargu/api/response)

;;; kargu/api/response.el ends here
