;;; client.el --- Chat send, cancel, connection test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; High-level API transport: `kargu-api-send', `kargu-api-cancel', `kargu-test-connection'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)
(require 'kargu/api/http)
(require 'kargu/api/wire)

(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-api-cancel "kargu/api/http" ())
(declare-function kargu-api-clear-busy "kargu/api/http" ())
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-provider-format-stream-p "kargu/providers/registry" (format))

(defalias 'kargu--api-cancel-busy #'kargu-api-clear-busy)

(defun kargu--api-validate-preflight (prompt)
  "Validate preflight conditions before sending conversation turn with PROMPT."
  ;; Guard Clause 3: Completed assistant turn cannot continue without prompt
  (when (and (or (null prompt) (string-empty-p prompt))
             (kargu--history-completed-assistant-tail-p))
    (user-error "Nothing to continue; send a user message"))
  (kargu--validate-history)
  ;; Guard Clause 4: History must contain at least one user message
  (unless (cl-some (lambda (m)
                     (equal (kargu-aget m "role") "user"))
                   kargu--message-history)
    (user-error "Nothing to send: history has no user message"))
  ;; Guard Clause 5: History must not end on model turn
  (when (kargu--assistant-role-p (kargu--history-last-role))
    (user-error "Refusing to send: history still ends on a model turn")))

(defun kargu--api-rollback-prompt (prompt added-prompt-p)
  "Roll back PROMPT from history if ADDED-PROMPT-P is non-nil."
  (when (and added-prompt-p
             kargu--message-history
             (equal (kargu-aget (car (last kargu--message-history)) "role") "user")
             (equal (kargu-aget (car (last kargu--message-history)) "content") prompt))
    (setq kargu--message-history (butlast kargu--message-history))))

(defun kargu--api-refuse (callback message)
  "Tell CALLBACK the request is refused for MESSAGE.  Return nil."
  (funcall callback `(("error" . (("message" . ,message)))))
  nil)

(defun kargu-api-send (prompt callback &optional on-delta)
  "Send the next conversation turn to the active provider asynchronously.
PROMPT is the new user message (a string), or nil to continue from history.
CALLBACK is called with one argument: the decoded response alist.
ON-DELTA is called with each streaming SSE delta event.
A busy client, a missing key, or a missing endpoint is refused first."
  (kargu-contract-assert #'kargu-contract-prompt-p prompt
                         "PROMPT must be a string or nil: %S" prompt)
  (kargu-contract-assert #'functionp callback
                         "CALLBACK must be callable: %S" callback)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "ON-DELTA must be callable or nil: %S" on-delta)
  (let ((key (and (not kargu--busy) (kargu--resolve-api-key)))
        (base (and (not kargu--busy) (kargu--api-base))))
    (cond
     (kargu--busy
      (kargu--api-refuse callback "request already in flight; cancel first"))
     ((null key)
      (kargu--api-refuse callback "no API key: M-x kargu-edit-config, or set `kargu-api-key', or a host env/auth-source entry"))
     ((not (kargu-nonempty base))
      (kargu--api-refuse callback "no API endpoint: set api on the active provider"))
     (t
      (kargu-api--send-turn :prompt prompt :callback callback :on-delta on-delta
                            :key key :base base)))))

(cl-defun kargu-api--send-turn (&key prompt callback on-delta key base)
  "Append PROMPT and start a request using KEY and BASE.
Deliver events to ON-DELTA and the response to CALLBACK."
  (let ((added-prompt-p (and prompt (not (string-empty-p prompt)))))
    (when added-prompt-p (kargu--history-add "user" prompt))
    (condition-case-unless-debug err
        (progn
          (kargu--api-validate-preflight prompt)
          (kargu-api--start-turn :callback callback :on-delta on-delta
                                 :key key :base base))
      (error
       (kargu--api-cancel-busy)
       (kargu--api-rollback-prompt prompt added-prompt-p)
       (funcall callback (kargu--api-error-alist (error-message-string err)))))))

(cl-defun kargu-api--start-turn (&key callback on-delta key base)
  "Post the validated history using KEY and BASE.
Deliver events to ON-DELTA and the response to CALLBACK."
  (let* ((gen (cl-incf kargu--generation))
         (fmt (kargu-api-active-format))
         (payload (kargu-api-prepare-payload (kargu--build-payload) fmt))
         (delta (and (kargu-provider-format-stream-p fmt) on-delta)))
    (setq kargu--busy t)
    (kargu-state-transition-status :requesting)
    (kargu--api-post
     (kargu-api-chat-url base fmt) (kargu--api-headers key) payload gen
     (lambda (response)
       (kargu--api-cancel-busy)
       (funcall callback response))
     delta)))

(defun kargu-test-connection ()
  "Ping the active provider with a minimal request and report the result.
The conversation history is untouched: the ping uses a scratch
history which is restored afterwards."
  (interactive)
  ;; Guard Clause 1: Loop active
  (when (and (fboundp 'kargu-loop-running-p)
             (kargu-loop-running-p))
    (user-error
     "An agent run is in progress; stop it first (M-x kargu-loop-stop)"))
  ;; Guard Clause 2: Circuit breaker status
  (when (kargu-circuit-open-p)
    (user-error "Circuit breaker is %s; cannot ping until cooldown"
                (kargu-circuit-status-string)))
  (let ((saved kargu--message-history))
    (setq kargu--message-history nil)
    (kargu--history-add "user" "Reply with the single word: pong")
    (message "kargu: pinging %s (%s)..." (kargu--provider-name) (kargu--model))
    (let ((kargu-temperature nil)
          (kargu-max-tokens 32))
      (kargu-api-send
       nil
       (lambda (response)
         ;; The reply was stored into the scratch history; the real one is
         ;; put back before anything else can look at it.
         (setq kargu--message-history saved)
         (kargu--report-ping response))))))

(defun kargu--report-ping (response)
  "Tell the user how the connection test RESPONSE went."
  (let ((err (kargu-response-error-message response)))
    (if err
        (progn
          (kargu-log 'error "test-connection: %s" err)
          (message "kargu: FAILED — %s" err))
      (message "kargu: OK — model replied: %s"
               (truncate-string-to-width
                (or (kargu-response-text response) "") 60)))))

(provide 'kargu/api/client)

;;; client.el ends here
