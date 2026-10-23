;;; wire.el --- Format-record request and response bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; The core speaks OpenAI chat completions.  A catalog format record
;; says how that body is posted and how the reply comes back.
;; `blocks' is the Messages shape: system text is lifted, tool
;; results become content blocks, and the reply is one choice.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/providers/catalog)
(require 'kargu/api/tool-calls)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-format-record "kargu/providers/registry" (format))
(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu-connection-current "kargu/config/connection" ())
(declare-function kargu-connection-setting "kargu/config/connection" (name &optional snapshot))

(defun kargu-api-wire-record (format)
  "Return FORMAT's captured wire record inside a connection boundary."
  (if (kargu-connection-current)
      (kargu-connection-setting :wire)
    (kargu-provider-format-record format)))

(defun kargu-api--as-list (value)
  "VALUE as a list.  Vectors become lists.  Other types become nil."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun kargu-api-active-format ()
  "Catalog format symbol of the active provider, or nil."
  (if (kargu-connection-current)
      (kargu-connection-setting :format)
    (when (fboundp 'kargu-provider-format)
    (let ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
      (kargu-provider-format
       (downcase (string-trim (format "%s" (or pname "")))))))))

(defun kargu-api-chat-url (base format)
  "Chat endpoint for BASE and catalog FORMAT.
The path comes from the format record.  A missing record uses
`/chat/completions'."
  (let ((path (or (plist-get (kargu-api-wire-record format) :chat-path)
                  "/chat/completions")))
    (concat base path)))

(defun kargu-api--block-spec (spec role)
  "Block plist in SPEC whose :as is ROLE, or nil."
  (cl-find role (plist-get spec :blocks)
           :key (lambda (block) (plist-get block :as))))


(defun kargu-api--tool-input (raw)
  "JSON object for a tool-call argument string RAW."
  (cond
   ((and (stringp raw) (not (string-empty-p raw)))
    (or (kargu--json-decode-safe raw) :json-empty-object))
   ((or (null raw) (eq raw :json-null)) :json-empty-object)
   (t raw)))

(defun kargu-api--tool-use-block (call spec)
  "One tool_use block for an OpenAI tool call CALL, shaped by SPEC."
  (let* ((block (kargu-api--block-spec spec 'tool-call))
         (fn (kargu-aget call "function")))
    (list (cons "type" (plist-get block :type))
          (cons (plist-get block :id)
                (or (kargu-nonempty (kargu-aget call "id"))
                    (error "Cannot send a tool call without its canonical identity")))
          (cons (plist-get block :name) (or (kargu-aget fn "name") "tool"))
          (cons (plist-get block :input)
                (kargu-api--tool-input (kargu-aget fn "arguments"))))))

(defun kargu-api--tool-def (tool spec)
  "One tool definition for an OpenAI TOOL entry, shaped by SPEC."
  (let* ((fn (or (kargu-aget tool "function") tool))
         (name (kargu-aget fn "name"))
         (schema (plist-get spec :tool-schema-key)))
    (when (and (stringp name) (not (string-empty-p name)) schema)
      (append (list (cons "name" name)
		    (cons "description" (or (kargu-aget fn "description") ""))
		    (cons schema (or (kargu-aget fn "parameters")
				     :json-empty-object)))
              (when-let* ((marker (kargu-aget tool "cache_control")))
                (list (cons "cache_control" marker)))))))

(defun kargu-api--text-blocks (content spec)
  "Return content blocks for CONTENT using SPEC, preserving cache markers."
  (cond
   ((and (stringp content) (not (string-empty-p content)))
    (let ((text (kargu-api--block-spec spec 'text)))
      (list (list (cons "type" (plist-get text :type))
                  (cons (plist-get text :field) content)))))
   ((or (listp content) (vectorp content))
    (copy-tree (kargu-api--as-list content) t))))

(defun kargu-api--assistant-blocks (msg spec)
  "Return text and tool-use blocks for MSG under SPEC."
  (let ((blocks (reverse (kargu-api--text-blocks (kargu-aget msg "content") spec))))
    (dolist (call (kargu-api--as-list (kargu-aget msg "tool_calls")))
      (push (kargu-api--tool-use-block call spec) blocks))
    (nreverse blocks)))

(defun kargu-api--tool-result-block (msg spec)
  "One tool_result block for an OpenAI tool MSG, shaped by SPEC."
  (let ((result (plist-get spec :tool-result)))
    (list (cons "type" (plist-get result :type))
          (cons (plist-get result :id)
                (or (kargu-aget msg "tool_call_id") ""))
          (cons (plist-get result :content)
                (or (kargu-aget msg "content") "")))))

(defun kargu-api--push-user (blocks out)
  "Cons a user message of BLOCKS onto OUT."
  (if blocks
      (cons `(("role" . "user") ("content" . ,(nreverse blocks))) out)
    out))

(defun kargu-api--blocks-messages (messages spec)
  "Return (SYSTEM . MESSAGES) for OpenAI MESSAGES shaped by SPEC.
SYSTEM is a content-block list, preserving explicit cache boundaries."
  (let (system out pending)
    (dolist (msg messages)
      (pcase (kargu-aget msg "role")
        ("system"
         (dolist (block (kargu-api--text-blocks (kargu-aget msg "content") spec))
           (push block system)))
        ("tool" (push (kargu-api--tool-result-block msg spec) pending))
        ("assistant"
         (setq out (kargu-api--push-user pending out) pending nil)
         (when-let* ((blocks (kargu-api--assistant-blocks msg spec)))
           (push `(("role" . "assistant") ("content" . ,blocks)) out)))
        (_
         (dolist (block (kargu-api--text-blocks (kargu-aget msg "content") spec))
           (push block pending))
         (setq out (kargu-api--push-user pending out) pending nil))))
    (setq out (kargu-api--push-user pending out))
    (cons (nreverse system) (nreverse out))))

(defun kargu-api--copy-present (payload keys)
  "Alist of KEYS that are present in PAYLOAD."
  (let (out)
    (dolist (key keys)
      (let ((val (kargu-aget payload key)))
        (when val
          (push (cons key val) out))))
    (nreverse out)))

(defun kargu-api--blocks-payload (payload spec)
  "Messages body for an OpenAI-shaped PAYLOAD, using SPEC."
  (let* ((split (kargu-api--blocks-messages
                 (kargu-api--as-list (kargu-aget payload "messages"))
                 spec))
         (system (car split))
         (messages (cdr split))
         (tools (delq nil (mapcar (lambda (tool)
                                    (kargu-api--tool-def tool spec))
                                  (kargu-api--as-list (kargu-aget payload "tools")))))
         (max-tokens (or (kargu-aget payload "max_tokens")
                         (plist-get spec :max-tokens-default)))
         (body (append
                `(("model" . ,(kargu-aget payload "model"))
                  ("max_tokens" . ,max-tokens)
                  ("messages" . ,messages))
                (kargu-api--copy-present payload (plist-get spec :copy-keys)))))
    (when (and system (plist-get spec :system-key))
      (push (cons (plist-get spec :system-key) system) body))
    (when tools
      (setq body (append body `(("tools" . ,(vconcat tools))))))
    body))

(defun kargu-api-prepare-payload (payload format)
  "PAYLOAD ready to post for catalog FORMAT.
A `blocks' message shape is rewritten.  Every other shape is unchanged."
  (let ((spec (kargu-api-wire-record format)))
    (if (eq (plist-get spec :message-shape) 'blocks)
        (kargu-api--blocks-payload payload spec)
      payload)))

(defun kargu-api--stop-value (response spec)
  "Stop token in RESPONSE under SPEC's detect keys, or nil."
  (cl-some (lambda (key) (kargu-aget response key))
           (plist-get spec :detect)))

(defun kargu-api--finish (stop spec)
  "OpenAI finish_reason for STOP under SPEC."
  (or (cdr (assoc stop (plist-get spec :finish)))
      (plist-get spec :finish-default)
      "stop"))

(defun kargu-api--blocks-choice (response spec)
  "OpenAI choice alist for a blocks RESPONSE shaped by SPEC."
  (let ((text "")
        (thought "")
        (text-spec (kargu-api--block-spec spec 'text))
        (reason-spec (kargu-api--block-spec spec 'reasoning))
        (tool-spec (kargu-api--block-spec spec 'tool-call))
        calls)
    (dolist (block (kargu-api--as-list
                    (kargu-aget response (or (plist-get spec :content-key) "content"))))
      (let ((kind (kargu-aget block "type")))
        (cond
         ((and text-spec (equal kind (plist-get text-spec :type)))
          (setq text (concat text (or (kargu-aget block (plist-get text-spec :field)) ""))))
         ((and reason-spec (equal kind (plist-get reason-spec :type)))
          (setq thought (concat thought
                                (or (kargu-aget block (plist-get reason-spec :field)) ""))))
         ((and tool-spec (equal kind (plist-get tool-spec :type)))
          (push `(("id" . ,(kargu-aget block (plist-get tool-spec :id)))
                  ("type" . "function")
                  ("function" . (("name" . ,(or (kargu-aget block (plist-get tool-spec :name)) "tool"))
                                 ("arguments" . ,(kargu-json-encode-record
                                                  (or (kargu-aget block (plist-get tool-spec :input))
                                                      :json-empty-object))))))
                calls)))))
    (let ((message `(("role" . "assistant")
                     ("content" . ,text))))
      (when calls
        (push (cons "tool_calls" (vconcat (nreverse calls))) message))
      (when (not (string-empty-p thought))
        (push (cons "reasoning_content" thought) message))
      `(("message" . ,message)
        ("finish_reason" . ,(kargu-api--finish
                             (kargu-api--stop-value response spec)
                             spec))))))

(defun kargu-api--usage (response spec)
  "Normalize RESPONSE usage under SPEC without inventing missing counters."
  (when-let* ((usage (kargu-aget response "usage")))
    (let* ((mapped (delq nil (mapcar (lambda (pair)
                                       (when-let* ((value (kargu-aget usage (car pair))))
                                         (cons (cdr pair) value)))
                                     (plist-get spec :usage))))
           (cache (plist-get spec :cache-usage))
           (read (kargu-aget usage (plist-get cache :read)))
           (write (kargu-aget usage (plist-get cache :write)))
           (input (kargu-aget mapped "prompt_tokens")))
      (when (and (numberp input) (plist-get cache :input-excludes-cache))
        (setcdr (assoc "prompt_tokens" mapped)
                (+ input (if (numberp read) read 0) (if (numberp write) write 0))))
      (when (or (numberp read) (numberp write))
        (push (cons "prompt_tokens_details"
                    (append (and (numberp read) (list (cons "cached_tokens" read)))
                            (and (numberp write) (list (cons "cache_write_tokens" write)))))
              mapped))
      mapped)))

(defun kargu-api--blocks-response-p (response spec)
  "Non-nil when RESPONSE matches SPEC's detect rules."
  (or (cl-some (lambda (key) (kargu-aget response key))
               (plist-get spec :detect))
      (and (plist-get spec :detect-type)
           (equal (kargu-aget response "type")
                  (plist-get spec :detect-type)))))

(defun kargu-api--blocks-spec (response)
  "Format record whose blocks rules match RESPONSE, or nil."
  (if (kargu-connection-current)
      (let ((spec (kargu-connection-setting :wire)))
        (and (eq (plist-get spec :response-shape) 'blocks)
             (kargu-api--blocks-response-p response spec) spec))
    (cl-some (lambda (cell)
             (let ((spec (cdr cell)))
               (and (eq (plist-get spec :response-shape) 'blocks)
                    (kargu-api--blocks-response-p response spec)
                    spec)))
           kargu-provider-formats)))

(defun kargu-api-response-shape (response)
  "RESPONSE as an OpenAI chat-completions alist.
A blocks body becomes one choice.  Bodies that already have
`choices' or `error' pass through."
  (cond
   ((or (null response) (not (listp response))) response)
   ((kargu-aget response "choices") response)
   ((let ((error (kargu-aget response "error")))
      (and error (not (memq error '(:json-null :json-false))))) response)
   (t
    (let ((spec (kargu-api--blocks-spec response)))
      (if spec
          (let ((usage (kargu-api--usage response spec))
                (choice (kargu-api--blocks-choice response spec)))
            (append `(("choices" . (,choice)))
                    (and usage `(("usage" . ,usage)))))
        response)))))

(defun kargu-api-normalize-response (response)
  "Normalize RESPONSE's wire shape and tool identities before any consumer."
  (kargu-api-normalize-tool-calls (kargu-api-response-shape response)))

(provide 'kargu/api/wire)

;;; wire.el ends here
