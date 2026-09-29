;;; kargu/api/wire.el --- Format-record request and response bridge -*- lexical-binding: t; -*-

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

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-format-record "kargu/providers/registry" (format))
(declare-function kargu--provider-name "kargu/config/schema" ())

(defun kargu-api--as-list (value)
  "VALUE as a list.  Vectors become lists.  Other types become nil."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun kargu-api-active-format ()
  "Catalog format symbol of the active provider, or nil."
  (when (fboundp 'kargu-provider-format)
    (let ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
      (kargu-provider-format
       (downcase (string-trim (format "%s" (or pname ""))))))))

(defun kargu-api-chat-url (base format)
  "Chat endpoint for BASE and catalog FORMAT.
The path comes from the format record.  A missing record uses
`/chat/completions'."
  (let ((path (or (plist-get (kargu-provider-format-record format) :chat-path)
                  "/chat/completions")))
    (concat base path)))

(defun kargu-api--block-spec (spec role)
  "Block plist in SPEC whose :as is ROLE, or nil."
  (cl-find role (plist-get spec :blocks)
           :key (lambda (block) (plist-get block :as))))

(defun kargu-api--text (content)
  "String body of a message CONTENT value."
  (cond
   ((stringp content) content)
   ((null content) "")
   (t (format "%s" content))))

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
          (cons (plist-get block :id) (or (kargu-aget call "id") "call"))
          (cons (plist-get block :name) (or (kargu-aget fn "name") "tool"))
          (cons (plist-get block :input)
                (kargu-api--tool-input (kargu-aget fn "arguments"))))))

(defun kargu-api--tool-def (tool spec)
  "One tool definition for an OpenAI TOOL entry, shaped by SPEC."
  (let* ((fn (or (kargu-aget tool "function") tool))
         (name (kargu-aget fn "name"))
         (schema (plist-get spec :tool-schema-key)))
    (when (and (stringp name) (not (string-empty-p name)) schema)
      (list (cons "name" name)
            (cons "description" (or (kargu-aget fn "description") ""))
            (cons schema (or (kargu-aget fn "parameters")
                             :json-empty-object))))))

(defun kargu-api--assistant-blocks (msg spec)
  "Content blocks for an OpenAI assistant MSG, shaped by SPEC."
  (let ((text-spec (kargu-api--block-spec spec 'text))
        (text (kargu-api--text (kargu-aget msg "content")))
        (calls (kargu-api--as-list (kargu-aget msg "tool_calls")))
        blocks)
    (when (and text-spec (not (string-empty-p text)))
      (push (list (cons "type" (plist-get text-spec :type))
                  (cons (plist-get text-spec :field) text))
            blocks))
    (dolist (call calls)
      (push (kargu-api--tool-use-block call spec) blocks))
    (nreverse blocks)))

(defun kargu-api--tool-result-block (msg spec)
  "One tool_result block for an OpenAI tool MSG, shaped by SPEC."
  (let ((result (plist-get spec :tool-result)))
    (list (cons "type" (plist-get result :type))
          (cons (plist-get result :id)
                (or (kargu-aget msg "tool_call_id") ""))
          (cons (plist-get result :content)
                (kargu-api--text (kargu-aget msg "content"))))))

(defun kargu-api--push-user (blocks out)
  "Cons a user message of BLOCKS onto OUT."
  (if blocks
      (cons `(("role" . "user") ("content" . ,(nreverse blocks))) out)
    out))

(defun kargu-api--blocks-messages (messages spec)
  "Return (SYSTEM . MESSAGES) for OpenAI MESSAGES shaped by SPEC.
SYSTEM is a string or nil.  MESSAGES is a list of user and
assistant turns."
  (let ((join (or (plist-get spec :system-join) "\n\n"))
        system out pending)
    (dolist (msg messages)
      (let ((role (kargu-aget msg "role")))
        (cond
         ((equal role "system")
          (let ((text (kargu-api--text (kargu-aget msg "content"))))
            (unless (string-empty-p text)
              (setq system (if system (concat system join text) text)))))
         ((equal role "tool")
          (push (kargu-api--tool-result-block msg spec) pending))
         ((equal role "assistant")
          (setq out (kargu-api--push-user pending out))
          (setq pending nil)
          (let ((blocks (kargu-api--assistant-blocks msg spec)))
            (when blocks
              (push `(("role" . "assistant") ("content" . ,blocks)) out))))
         (t
          (let ((text-spec (kargu-api--block-spec spec 'text)))
            (push (list (cons "type" (plist-get text-spec :type))
                        (cons (plist-get text-spec :field)
                              (kargu-api--text (kargu-aget msg "content"))))
                  pending))
          (setq out (kargu-api--push-user pending out))
          (setq pending nil)))))
    (setq out (kargu-api--push-user pending out))
    (cons system (nreverse out))))

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
  (let ((spec (kargu-provider-format-record format)))
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
          (push `(("id" . ,(or (kargu-aget block (plist-get tool-spec :id)) "call"))
                  ("type" . "function")
                  ("function" . (("name" . ,(or (kargu-aget block (plist-get tool-spec :name)) "tool"))
                                 ("arguments" . ,(kargu--json-encode
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
  "OpenAI usage alist for RESPONSE under SPEC, or nil."
  (let ((usage (kargu-aget response "usage")))
    (when usage
      (mapcar (lambda (pair)
                (cons (cdr pair) (or (kargu-aget usage (car pair)) 0)))
              (plist-get spec :usage)))))

(defun kargu-api--blocks-response-p (response spec)
  "Non-nil when RESPONSE matches SPEC's detect rules."
  (or (cl-some (lambda (key) (kargu-aget response key))
               (plist-get spec :detect))
      (and (plist-get spec :detect-type)
           (equal (kargu-aget response "type")
                  (plist-get spec :detect-type)))))

(defun kargu-api--blocks-spec (response)
  "Format record whose blocks rules match RESPONSE, or nil."
  (cl-some (lambda (cell)
             (let ((spec (cdr cell)))
               (and (eq (plist-get spec :response-shape) 'blocks)
                    (kargu-api--blocks-response-p response spec)
                    spec)))
           kargu-provider-formats))

(defun kargu-api-normalize-response (response)
  "RESPONSE as an OpenAI chat-completions alist.
A blocks body becomes one choice.  Bodies that already have
`choices' or `error' pass through."
  (cond
   ((or (null response) (not (listp response))) response)
   ((kargu-aget response "choices") response)
   ((kargu-aget response "error") response)
   (t
    (let ((spec (kargu-api--blocks-spec response)))
      (if spec
          (let ((usage (kargu-api--usage response spec))
                (choice (kargu-api--blocks-choice response spec)))
            (append `(("choices" . (,choice)))
                    (and usage `(("usage" . ,usage)))))
        response)))))

(provide 'kargu/api/wire)

;;; kargu/api/wire.el ends here
