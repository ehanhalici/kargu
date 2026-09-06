;;; kargu/history.el --- Conversation history and protocol firewall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; OpenAI-shaped message queue and the send-time firewall.
;; Requires: `kargu/core', `kargu/prompt'.
;; Public: `kargu--history-add', `kargu-history-reset',
;; `kargu--validate-history', `kargu-history-inspect'.

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

;;;; Message history ------------------------------------------------------

(defvar kargu--message-history nil
  "Conversation history, oldest first.
Each element is an alist with string keys in the OpenAI
chat-completions shape: (\"role\" . \"system\"|\"user\"|\"assistant\"|\"tool\").
Assistant turns may carry (\"tool_calls\" . [...]); tool turns
carry (\"tool_call_id\" . \"...\").  The list is ALWAYS repaired
through `kargu--validate-history' before a request payload
is built from it, so it can be inspected safely at any time.")

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
(defalias 'kargu-history-validate #'kargu--validate-history)
(defalias 'kargu-history-empty-tail-p #'kargu--empty-assistant-tail-p)

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
  "Non-nil if ROLE is an assistant turn.
Gemini-style providers use `model' for the same turn; both
count so a stored `model' message is never treated as a user
or tool result."
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

(defun kargu--empty-assistant-tail-p ()
  "Non-nil when the history ends on a tool-less assistant turn.
Such a run must be repaired (stripped or nudged) rather than
treated as a valid conversation suffix.  Callers should not
invent a fake user message; callers should refuse instead."
  (let ((last (car (last kargu--message-history))))
    (and last
         (kargu--assistant-role-p (kargu--aget last "role"))
         (null (kargu--calls-to-list (kargu--aget last "tool_calls"))))))

(defalias 'kargu--history-completed-assistant-tail-p #'kargu--empty-assistant-tail-p)

;;;; Protocol firewall ----------------------------------------------------

(defcustom kargu-trailing-assistant-fix 'strip
  "How to repair a history that ends on an assistant (model) turn.
Such payloads are rejected by several OpenRouter providers with
\"Requests ending with a model turn are not supported\".
`strip' removes trailing assistant messages (protocol default);
`nudge' appends a minimal user message asking the model to continue."
  :type '(choice (const :tag "Drop trailing assistant messages" strip)
                 (const :tag "Append a user \"continue\" message" nudge))
  :group 'kargu)

(defconst kargu--continue-nudge "Continue."
  "Content of the synthetic user message used by the `nudge' fix.")

(defun kargu--calls-to-list (calls)
  "Convert CALLS to a list of tool-call alists, or nil if empty."
  (cond
   ((null calls) nil)
   ((eq calls :json-null) nil)
   ((vectorp calls)
    (if (= (length calls) 0) nil (append calls nil)))
   ((listp calls) (if (null calls) nil calls))
   (t nil)))

(defun kargu--clean-assistant-message (msg)
  "Return a normalized copy of assistant message MSG.
A null, :json-null or empty \"content\" is removed when the
message carries tool calls (several providers reject empty text
content blocks alongside tool calls)."
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

(defun kargu--flush-pending (pending out-rev)
  "Extend OUT-REV with synthetic tool results for unanswered calls.
PENDING is a hash table mapping tool-call ids to tool names; it
is cleared.  Synthetic results make an interrupted run
protocol-valid again and tell the model which tool failed."
  (when (> (hash-table-count pending) 0)
    (kargu-log 'warn
                     "validate: %d unanswered tool call(s); injecting synthetic error results"
                     (hash-table-count pending)))
  (maphash (lambda (id name)
             (push `(("role" . "tool")
                     ("tool_call_id" . ,id)
                     ("name" . ,name)
                     ("content" . "ERROR: interrupted before response"))
                   out-rev))
           pending)
  (clrhash pending)
  out-rev)

(defun kargu--validate-history ()
  "Enforce the protocol invariants required by chat providers.
Mutates `kargu--message-history' in place and returns it.

Invariants enforced:
1. Every message has role, content, and valid tool call / id shape.
2. Every tool result answers a preceding tool call (by id).
3. Every tool call has a result before the next user/assistant turn.
4. History never ends on an assistant/model turn (`strip' or `nudge').
5. Consecutive user messages are merged.
6. Empty assistant text alongside tool calls is dropped."
  (let* ((pending (make-hash-table :test #'equal))
         (out nil)
         (rest kargu--message-history))
    ;; 1. system head, refreshed on every request
    (if (and rest (equal (kargu--aget (car rest) "role") "system"))
        (let ((sys (pop rest)))
          (if (assoc "content" sys)
              (setcdr (assoc "content" sys) (kargu--get-system-prompt))
            (push `("content" . ,(kargu--get-system-prompt)) sys))
          (push sys out))
      (push `(("role" . "system")
              ("content" . ,(kargu--get-system-prompt)))
            out))
    ;; 2. walk the tail
    (dolist (raw rest)
      (let* ((msg (copy-tree raw))
             (role (kargu--aget msg "role")))
        (cond
         ((equal role "tool")
          (let ((id (kargu--aget msg "tool_call_id")))
            (if (and id (gethash id pending))
                (progn
                  (remhash id pending)
                  (push msg out))
              (kargu-log 'warn
                                "validate: dropping orphan tool result %s"
                                (or id "(no id)")))))
         ;; stray system messages are merged into the head
         ((equal role "system") nil)
         (t
          ;; any new turn must first answer dangling tool calls
          (setq out (kargu--flush-pending pending out))
           (cond
            ((and (kargu--assistant-role-p role)
                  (kargu--calls-to-list (kargu--aget msg "tool_calls")))
             (let* ((clean (kargu--clean-assistant-message
                            (kargu--normalize-assistant-role msg)))
                    (calls (kargu--calls-to-list (kargu--aget clean "tool_calls"))))
               (if (and out (kargu--assistant-role-p (kargu--aget (car out) "role"))
                        (not (kargu--calls-to-list (kargu--aget (car out) "tool_calls"))))
                   (let* ((prev (pop out))
                          (prev-txt (or (kargu--aget prev "content") ""))
                          (curr-txt (or (kargu--aget clean "content") ""))
                          (merged-txt (string-trim (concat prev-txt "\n\n" curr-txt))))
                     (when (not (string-empty-p merged-txt))
                       (if (assoc "content" clean)
                           (setcdr (assoc "content" clean) merged-txt)
                         (push `("content" . ,merged-txt) clean)))
                     (push clean out))
                 (push clean out))
               (dolist (call calls)
                 (when-let* ((id (kargu--aget call "id")))
                   (puthash id
                            (or (kargu--aget
                                 (kargu--aget call "function") "name")
                                "unknown")
                            pending)))))
            ((and (equal role "user")
                  (equal (kargu--aget (car out) "role") "user"))
             ;; 5. merge consecutive user messages
             (let ((prev (car out))
                   (extra (if (stringp (kargu--aget msg "content"))
                              (kargu--aget msg "content")
                            "")))
               (if (assoc "content" prev)
                   (setcdr (assoc "content" prev)
                           (concat (if (stringp (kargu--aget prev "content"))
                                       (kargu--aget prev "content")
                                     "")
                                   "\n\n" extra))
                 (setcar out (cons `("content" . ,extra) prev)))))
            ((and (kargu--assistant-role-p role)
                  out
                  (kargu--assistant-role-p (kargu--aget (car out) "role"))
                  (not (kargu--calls-to-list (kargu--aget (car out) "tool_calls"))))
             ;; Merge consecutive assistant text turns
             (let* ((prev (car out))
                    (extra (if (stringp (kargu--aget msg "content"))
                               (kargu--aget msg "content")
                             "")))
               (if (assoc "content" prev)
                   (setcdr (assoc "content" prev)
                           (string-trim
                            (concat (if (stringp (kargu--aget prev "content"))
                                        (kargu--aget prev "content")
                                      "")
                                    "\n\n" extra)))
                 (setcar out (cons `("content" . ,extra) prev)))))
            (t
             (when (kargu--assistant-role-p role)
                (kargu--normalize-assistant-role msg)
                (unless (or (kargu--calls-to-list (kargu--aget msg "tool_calls"))
                            (kargu--nonempty (kargu--aget msg "content")))
                  (if (assoc "content" msg)
                      (setcdr (assoc "content" msg) "")
                    (push '("content" . "") msg))))
             (push msg out)))))))
    ;; trailing dangling tool calls: inject synthetic results; the
    ;; history then correctly ends on tool messages
    (setq out (kargu--flush-pending pending out))
    ;; 4. never end on an assistant/model turn
    (when (and out (kargu--assistant-role-p (kargu--aget (car out) "role")))
      (if (eq kargu-trailing-assistant-fix 'strip)
          (while (and out
                      (kargu--assistant-role-p
                       (kargu--aget (car out) "role")))
            (pop out))
        (push `(("role" . "user")
                ("content" . ,kargu--continue-nudge))
              out)))
    (setq kargu--message-history (nreverse out))
    (kargu-log 'debug "validate: %d messages, last role %s"
                     (length kargu--message-history)
                     (kargu--history-last-role))
    (when (called-interactively-p 'any)
      (message "kargu history: %d messages, last role %s"
               (length kargu--message-history)
               (kargu--history-last-role)))
    kargu--message-history))

;;;; History inspection ---------------------------------------------------

(defun kargu-history-inspect ()
  "Dump the protocol view of the history to the log buffer.
Useful for diagnosing tool-call / tool-result pairing issues."
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

(provide 'kargu/history)

;;; kargu/history.el ends here
