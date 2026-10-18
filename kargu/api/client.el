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
  (kargu-api--send :prompt prompt :callback callback :on-delta on-delta))

(cl-defun kargu-api--send (&key prompt callback on-delta (record-turn t))
  "Validate connection settings and send PROMPT to CALLBACK and ON-DELTA.
RECORD-TURN permits storage of the reply in the active conversation."
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
                            :key key :base base :record-turn record-turn)))))

(cl-defstruct (kargu-api--delivery (:constructor kargu-api--make-delivery))
  "One turn's response owner, including a terminal single-delivery state."
  callback generation record-turn (state :pending))

(defun kargu-api--delivery-live-p (delivery)
  "Return non-nil when DELIVERY still owns the current request."
  (and (eq (kargu-api--delivery-state delivery) :pending)
       (= (kargu-api--delivery-generation delivery) kargu--generation)))

(defun kargu-api--deliver (delivery response)
  "Claim DELIVERY and store or forward RESPONSE exactly once."
  (when (kargu-api--delivery-live-p delivery)
    (setf (kargu-api--delivery-state delivery) :delivered)
    (let ((result
           (condition-case err
               (progn
                 (when (and (kargu-api--delivery-record-turn delivery)
                            (not (kargu-response-error-message response)))
                   (kargu-api-store-assistant-turn response))
                 response)
             (error (kargu--api-error-alist (error-message-string err))))))
      (when (= (kargu-api--delivery-generation delivery) kargu--generation)
        (kargu--api-cancel-busy))
      (condition-case err
          (funcall (kargu-api--delivery-callback delivery) result)
        (error (kargu-log 'error "API continuation failed: %s"
                          (error-message-string err)))))))

(cl-defun kargu-api--send-turn (&key prompt callback on-delta key base (record-turn t))
  "Append PROMPT and start a request using KEY and BASE.
Deliver events to ON-DELTA and the response to CALLBACK.
RECORD-TURN permits storage of the reply in the active conversation."
  (let ((added-prompt-p (and prompt (not (string-empty-p prompt))))
        (delivery (kargu-api--make-delivery :callback callback :record-turn record-turn
                                           :generation kargu--generation)))
    (when added-prompt-p (kargu--history-add "user" prompt))
    (condition-case-unless-debug err
        (progn
          (kargu--api-validate-preflight prompt)
          (kargu-api--start-turn :delivery delivery :on-delta on-delta
                                 :key key :base base))
      (error
       (when (kargu-api--delivery-live-p delivery)
         (kargu--api-rollback-prompt prompt added-prompt-p)
         (kargu-api--deliver delivery (kargu--api-error-alist (error-message-string err))))))))

(cl-defun kargu-api--start-turn (&key delivery on-delta key base)
  "Post the validated history using KEY and BASE.
Send events to ON-DELTA and the response through DELIVERY."
  (let ((gen (cl-incf kargu--generation)))
    (setf (kargu-api--delivery-generation delivery) gen)
    (let* ((fmt (kargu-api-active-format))
           (payload (kargu-api-prepare-payload (kargu--build-payload) fmt))
           (delta (and (kargu-provider-format-stream-p fmt) on-delta)))
      (setq kargu--busy t)
      (kargu-state-transition-status :requesting)
      (kargu--api-post
       (kargu-api-chat-url base fmt) (kargu--api-headers key) payload gen
       (lambda (response) (kargu-api--deliver delivery response))
       delta))))

(defun kargu-test-connection ()
  "Ping the active provider with a minimal request and report the result.
Build the payload in a temporary history binding; never store the reply."
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
  (let ((kargu--message-history nil)
        (kargu--system-key nil)
        (kargu--compaction-system "Reply briefly to the connectivity test.")
        (kargu--tools-visible-p #'ignore)
        (kargu-temperature nil)
        (kargu-max-tokens 32))
    (message "kargu: pinging %s (%s)..." (kargu--provider-name) (kargu--model))
    (kargu-api--send :prompt "Reply with the single word: pong"
                     :callback #'kargu--report-ping :record-turn nil)))

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
