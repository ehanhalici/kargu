;;; response.el --- Chat-completions response accessors -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Read text, tool_calls, finish_reason, overflow from a decoded response.  Also stores the assistant turn in history.
;; Requires: `kargu/core', `kargu/json', `kargu/history'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)

;;;; Accessors ---------------------------------------------------

(defun kargu--response-choice (response)
  "Return the first choice alist of RESPONSE, or nil."
  (let ((choices (kargu-aget response "choices")))
    (cond
     ((consp choices) (car choices))
     ((vectorp choices) (and (> (length choices) 0) (aref choices 0)))
     (t nil))))

(defun kargu--response-message (response)
  "Return the message alist of RESPONSE's first choice, or nil."
  (let ((choice (kargu--response-choice response)))
    (and choice (kargu-aget choice "message"))))

(defun kargu-response-text (response)
  "Return the user-visible assistant `content' of RESPONSE, or nil.
Reasoning fields are ignored."
  (kargu--content-text (kargu--response-message response)))

(defun kargu-response-tool-calls (response)
  "Return the tool-call alists of RESPONSE, or nil.
A legacy OpenAI `function_call' object is wrapped as one call."
  (let ((message (kargu--response-message response)))
    (or (and message (kargu-aget message "tool_calls"))
        (let ((legacy (and message (kargu-aget message "function_call"))))
          (when (and legacy (kargu--object-p legacy))
            `((("type" . "function")
               ("function" . ,legacy))))))))

(defun kargu-response-finish-reason (response)
  "Return the finish_reason of RESPONSE's first choice, or nil."
  (let ((choice (kargu--response-choice response)))
    (and choice (kargu-aget choice "finish_reason"))))

(defun kargu-response-error-message (response)
  "Return the error message inside RESPONSE, or nil.
RESPONSE may be a decoded OpenRouter error body or one of the
synthetic error alists produced by this module.  Nested
`error.message' and `error.metadata' fields are flattened."
  (when-let* ((err (kargu-aget response "error")))
    (cond
     ((memq err '(:json-null :json-false)) nil)
     ((stringp err) err)
     ((kargu--object-p err)
      (or (kargu--provider-error-text `(("error" . ,err)))
          (kargu-aget err "message")
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
  "Check MSG for nonempty structured tool invocations."
  (let ((calls (and msg (kargu-aget msg "tool_calls"))))
    (cond
     ((null calls) nil)
     ((eq calls :json-null) nil)
     ((vectorp calls) (> (length calls) 0))
     ((listp calls) (not (null calls)))
     (t nil))))

(defconst kargu-api--context-overflow-pattern
  (rx (or "context_length" "context length" "maximum context"
          "context window" "prompt is too long" "input is too long"
          (seq "exceed" (opt "s") " the context")))
  "Explicit context-length errors, excluding token-rate and output limits.")

(defun kargu--overflow-message-p (msg)
  "Return non-nil if MSG indicates context-window overflow."
  (and (stringp msg)
       (save-match-data
         (string-match-p kargu-api--context-overflow-pattern (downcase msg)))))

(defun kargu-response-overflow-p (response)
  "Non-nil when RESPONSE is a context-window overflow error."
  (or (kargu-aget response "overflow")
      (kargu--overflow-message-p (kargu-response-error-message response))))

(defun kargu--api-error-alist (msg)
  "Build a callback error alist from MSG, marking overflow when detected."
  (let ((err `(("error" . (("message" . ,msg))))))
    (when (kargu--overflow-message-p msg)
      (setq err (append err '(("overflow" . t)))))
    err))

(defun kargu--log-assistant-wire (response)
  "Wire-dump reconstructed assistant fields of RESPONSE."
  (when kargu-log-wire
    (let* ((choice (kargu--response-choice response))
           (msg (kargu--response-message response))
           (finish (and choice (kargu-aget choice "finish_reason")))
           (content (or (kargu--content-text msg) ""))
           (reason (or (kargu--reasoning-text msg) ""))
           (raw-calls (and msg (kargu-aget msg "tool_calls")))
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
                        (kargu-aget call "function")))
               (name (or (and fn (kargu-aget fn "name")) "?"))
               (args (and fn (kargu-aget fn "arguments")))
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
  "Normalize each tool call in MSG to a valid JSON argument object."
  (let ((calls (and msg (kargu-aget msg "tool_calls"))))
    (dolist (call (cond
                   ((vectorp calls) (append calls nil))
                   ((listp calls) calls)
                   (t nil)))
      (when-let* ((fn (and (kargu--object-p call)
                           (kargu-aget call "function")))
                  (cell (and fn (assoc "arguments" fn))))
        (setcdr cell (kargu--encode-tool-arguments (cdr cell)))))))

(defun kargu--normalize-history-content (msg content calls-p)
  "Normalize CONTENT in MSG alist based on whether CALLS-P is true.
Returns the updated message alist."
  (let ((cell (assoc "content" msg)))
    (cond
     ((kargu-nonempty content)
      (if cell
          (progn (setcdr cell content) msg)
        (cons `("content" . ,content) msg)))
     (calls-p
      (cl-remove-if (lambda (c) (equal (car c) "content")) msg))
     (t
      (if cell
          (progn (setcdr cell "") msg)
        (cons '("content" . "") msg))))))

(defun kargu--normalize-history-reasoning (msg reason)
  "Strip transient reasoning keys and update reasoning_content with REASON in MSG.
Returns the updated message alist."
  (let ((cleaned msg))
    (dolist (key '("reasoning" "reasoning_details" "thinking" "thought"))
      (setq cleaned (cl-remove-if (lambda (c) (equal (car c) key)) cleaned)))
    (let ((rc (assoc "reasoning_content" cleaned)))
      (cond
       ((kargu-nonempty reason)
        (if rc
            (progn (setcdr rc reason) cleaned)
          (cons `("reasoning_content" . ,reason) cleaned)))
       (rc
        (cl-remove-if (lambda (c) (equal (car c) "reasoning_content")) cleaned))
       (t cleaned)))))

(defun kargu--history-append-assistant (response &optional history)
  "Append RESPONSE's assistant message to HISTORY or current owner; return it.
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
           (reason (kargu--reasoning-text message)))
      (setq msg (kargu--normalize-history-content msg content calls-p))
      (setq msg (kargu--normalize-history-reasoning msg reason))
      (kargu--history-sanitize-tool-calls msg)
      (setq calls-p (kargu--assistant-has-tool-calls-p msg))
      (cond
       ((and (not (kargu-nonempty content))
             (not calls-p)
             (not (kargu-nonempty reason)))
        (kargu-log 'debug "skipping empty assistant turn")
        nil)
       (t
        (unless content
          (kargu-log 'debug "assistant content empty (type=%s, tools=%s)"
                     (type-of (kargu-aget message "content"))
                     (and calls-p t)))
        (setq msg (kargu-history-append msg history))
        (kargu--log-assistant-wire response)
        (kargu-log 'response "assistant turn stored: %d chars text, %d chars reasoning, %d tool call(s)"
                   (length (or content ""))
                   (length (or reason ""))
                   (length (or (kargu-aget msg "tool_calls") ())))
        msg)))))

(defalias 'kargu-api-store-assistant-turn #'kargu--history-append-assistant)

(provide 'kargu/api/response)

;;; response.el ends here
