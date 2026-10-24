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
(require 'kargu/application/coordinator)
(require 'kargu/application/budget)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/circuit)
(require 'kargu/api/http)
(require 'kargu/api/wire)
(require 'kargu/api/prepare)

(declare-function kargu-execution-request-started "kargu/application/execution" ())

(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-provider-format-stream-p "kargu/providers/registry" (format))

(defalias 'kargu--api-cancel-busy #'kargu-api-clear-busy)

(defun kargu-api-clear-busy ()
  "Release the request and update application status when no loop is active."
  (kargu-http-clear-busy)
  (unless (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (kargu-state-transition-status :idle)))

(defun kargu-api-cancel ()
  "Cancel the current request and update application status when appropriate."
  (interactive)
  (kargu-http-cancel)
  (unless (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (kargu-state-transition-status :idle "user cancelled"))
  (message "kargu: cancelled in-flight request"))

(defun kargu--api-validate-preflight (prompt &optional history)
  "Check PROMPT and repair HISTORY before sending; default to current owner."
  ;; Guard Clause 3: Completed assistant turn cannot continue without prompt
  (when (and (or (null prompt) (string-empty-p prompt))
             (kargu--history-completed-assistant-tail-p history))
    (user-error "Nothing to continue; send a user message"))
  (kargu--validate-history nil history)
  ;; Guard Clause 4: History must contain at least one user message
  (unless (cl-some (lambda (m)
                     (equal (kargu-aget m "role") "user"))
                   (kargu-history-messages history))
    (user-error "Nothing to send: history has no user message"))
  ;; Guard Clause 5: History must not end on model turn
  (when (kargu--assistant-role-p (kargu--history-last-role history))
    (user-error "Refusing to send: history still ends on a model turn")))

(defun kargu--api-rollback-prompt (prompt added-prompt-p &optional history)
  "Remove PROMPT from HISTORY if ADDED-PROMPT-P and it is still the tail."
  (when (and added-prompt-p
             (equal (kargu-aget (kargu-history-last-message history) "role") "user")
             (equal (kargu-aget (kargu-history-last-message history) "content") prompt))
    (kargu-history-replace (butlast (kargu-history-messages history)) history)))

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

(cl-defstruct (kargu-api--delivery (:constructor kargu-api--make-delivery))
  "One turn's response owner, including a terminal single-delivery state."
  callback generation record-turn request (app (kargu-application-context)) (state :pending)
  (origin (current-buffer)) (session (kargu-session-context))
  (history (kargu-history-context)))

(cl-defun kargu-api--send (&key prompt callback on-delta (record-turn t) history)
  "Validate connection settings and send PROMPT to CALLBACK and ON-DELTA.
RECORD-TURN permits reply storage.  HISTORY overrides the request's drafts."
  (cond
   ((kargu-busy-p) (kargu--api-refuse callback "request already in flight; cancel first"))
   ((kargu-connection-current)
    (kargu-api--send-turn
     :prompt prompt :callback callback :on-delta on-delta :record-turn record-turn :history history
     :key (kargu-connection-snapshot-secret (kargu-connection-current))
     :base (kargu-connection-snapshot-endpoint (kargu-connection-current))))
   (t (kargu-api--prepare-turn :prompt prompt :callback callback :on-delta on-delta
                              :record-turn record-turn :history history))))

(cl-defun kargu-api--prepare-turn (&key prompt callback on-delta record-turn history)
  "Reserve PROMPT's request before preparing CALLBACK, ON-DELTA and HISTORY.
RECORD-TURN controls whether a successful response enters history."
  (let* ((delivery (kargu-api--make-delivery
                    :callback callback :record-turn record-turn :history (kargu-history-context history)
                    :generation (kargu-application-next-generation)))
         (request (kargu-http--ensure-logical-request
                   (kargu-api--delivery-generation delivery)
                   (kargu-api--delivery-session delivery) (kargu-api--delivery-origin delivery))))
    (setf (kargu-api--delivery-request delivery) request)
    (kargu-state-transition-status :requesting)
    (when (kargu-api--delivery-owner-live-p delivery)
      (let ((task (kargu-api-prepare-connection
                   (lambda (result) (kargu-api--prepared delivery prompt on-delta result)))))
        (setf (kargu-logical-request-preparation request) task)
        (kargu-logical-request-add-cleanup request (lambda () (kargu-async-cancel task)))))))

(defun kargu-api--prepared (delivery prompt on-delta result)
  "Send PROMPT with ON-DELTA for DELIVERY after preparation RESULT."
  (cond
   ((not (kargu-api--delivery-owner-live-p delivery))
    (when (kargu-ok-p result) (kargu-connection-snapshot-wipe (kargu-result-value result))))
   ((kargu-err-p result)
    (kargu-api--deliver delivery (kargu--api-error-alist (kargu-result-err-message result))))
   (t
    (let ((snapshot (kargu-result-value result)))
      (kargu-logical-request-add-cleanup
       (kargu-api--delivery-request delivery) (lambda () (kargu-connection-snapshot-wipe snapshot)))
      (kargu-connection-call
       snapshot #'kargu-api--send-turn :prompt prompt :on-delta on-delta :delivery delivery
       :key (kargu-connection-snapshot-secret snapshot)
       :base (kargu-connection-snapshot-endpoint snapshot))))))

(defun kargu-api--delivery-owner-live-p (delivery)
  "Return non-nil if DELIVERY still owns its buffer and captured session."
  (let ((origin (kargu-api--delivery-origin delivery)))
    (and (= (kargu-api--delivery-generation delivery)
            (kargu-application-current-generation (kargu-api--delivery-app delivery)))
         (or (null (kargu-api--delivery-request delivery))
             (kargu-logical-request-current-p (kargu-api--delivery-request delivery) t))
         (buffer-live-p origin)
         (eq (kargu-api--delivery-session delivery) (kargu-session-context origin)))))

(defun kargu-api--delivery-live-p (delivery)
  "Return non-nil when DELIVERY still owns the current request."
  (and (eq (kargu-api--delivery-state delivery) :pending)
       (= (kargu-api--delivery-generation delivery)
          (kargu-application-current-generation (kargu-api--delivery-app delivery)))
       (or (null (kargu-api--delivery-request delivery))
           (kargu-logical-request-current-p (kargu-api--delivery-request delivery) t))))

(defun kargu-api--deliver (delivery response)
  "Claim DELIVERY and store or forward RESPONSE exactly once."
  (when (kargu-api--delivery-live-p delivery)
    (setf (kargu-api--delivery-state delivery) :delivered)
    (let ((result (when (kargu-api--delivery-owner-live-p delivery)
                    (with-current-buffer (kargu-api--delivery-origin delivery)
                      (condition-case err
                          (kargu-api--receive-owned delivery response)
                        (error (kargu--api-error-alist (error-message-string err))))))))
      (when (= (kargu-api--delivery-generation delivery)
               (kargu-application-current-generation (kargu-api--delivery-app delivery)))
        (kargu--api-cancel-busy))
      (when (kargu-api--delivery-owner-live-p delivery)
        (with-current-buffer (kargu-api--delivery-origin delivery)
          (condition-case err
              (funcall (kargu-api--delivery-callback delivery) result)
            (error (kargu-log 'error "API continuation failed: %s"
                              (error-message-string err)))))))))

(defun kargu-api--receive-owned (delivery response)
  "Record RESPONSE only in DELIVERY's captured, still-live owner."
  (setq response (kargu-api-normalize-tool-calls
                  response (kargu-api--delivery-history delivery)))
  (unless (kargu-response-error-message response)
    (kargu--record-usage response (kargu-api--delivery-session delivery))
    (when (and (kargu-api--delivery-record-turn delivery)
               (kargu-api--delivery-owner-live-p delivery))
      (kargu-api-store-assistant-turn response (kargu-api--delivery-history delivery))))
  response)

(cl-defun kargu-api--send-turn (&key prompt callback on-delta key base (record-turn t) history delivery)
  "Append PROMPT and start a request using KEY and BASE.
Deliver events to ON-DELTA and the response to CALLBACK.
RECORD-TURN permits reply storage; HISTORY supplies drafts.
DELIVERY retains the captured admission owner."
  (let* ((history (if delivery (kargu-api--delivery-history delivery)
                    (kargu-history-context history)))
         (added-prompt-p (and prompt (not (string-empty-p prompt))))
         (delivery (or delivery (kargu-api--make-delivery :callback callback :record-turn record-turn
                                             :history history
                                             :generation (kargu-application-current-generation)))))
    (when added-prompt-p
      (kargu-history-append `(("role" . "user") ("content" . ,prompt)) history))
    (condition-case-unless-debug err
        (progn
          (kargu--api-validate-preflight prompt history)
          (kargu-api--start-turn :delivery delivery :on-delta on-delta
                                 :key key :base base))
      (error
       (when (kargu-api--delivery-live-p delivery)
         (kargu--api-rollback-prompt prompt added-prompt-p history)
         (kargu-api--deliver delivery (kargu--api-error-alist (error-message-string err))))))))

(cl-defun kargu-api--start-turn (&key delivery on-delta key base)
  "Post the validated history using KEY and BASE.
Send events to ON-DELTA and the response through DELIVERY."
  (let ((gen (if (kargu-api--delivery-request delivery)
                 (kargu-api--delivery-generation delivery)
               (kargu-application-next-generation))))
    (setf (kargu-api--delivery-generation delivery) gen)
    (let* ((fmt (kargu-api-active-format))
           (payload (kargu-api-build-payload (kargu-api--delivery-history delivery)))
           (wire (kargu-api-wire-record fmt))
           (delta (and (or (null wire) (not (plist-member wire :stream))
                           (plist-get wire :stream)) on-delta)))
      (setf (kargu-api--delivery-request delivery)
            (kargu-http--ensure-logical-request
             gen
             (kargu-api--delivery-session delivery)
             (kargu-api--delivery-origin delivery)))
      (setf (kargu-logical-request-connection (kargu-api--delivery-request delivery))
            (kargu-connection-current))
      (unless kargu-application-owner (setq kargu--busy t))
      (kargu-state-transition-status :requesting)
      (cond
       ((and (kargu-api--delivery-live-p delivery)
             (kargu-api--delivery-owner-live-p delivery))
        (when (fboundp 'kargu-execution-request-started) (kargu-execution-request-started))
        (when (kargu-api--delivery-owner-live-p delivery)
          (kargu--api-post
           (kargu-api-chat-url base fmt) (kargu-api-auth-intent key) payload gen
           (lambda (response) (kargu-api--deliver delivery response)) delta)))
       ((= gen (kargu-application-current-generation))
        (kargu-http-clear-busy)
        (kargu-api--deliver delivery
                            (kargu--api-error-alist "Request owner was invalidated")))))))

(defun kargu-test-connection ()
  "Ping the active provider with a minimal request and report the result.
Build the payload in an isolated history; never store the reply."
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
  (let ((history (kargu-history-create))
        (kargu--tools-visible-p #'ignore)
        (kargu-temperature nil)
        (kargu-max-tokens 32))
    (kargu-history-set-overlay "Reply briefly to the connectivity test." history)
    (message "kargu: pinging %s (%s)..." (kargu--provider-name) (kargu--model))
    (kargu-api--send :prompt "Reply with the single word: pong"
                     :callback #'kargu--report-ping :record-turn nil :history history)))

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

(defun kargu--record-usage (response &optional session)
  "Accumulate RESPONSE usage in captured SESSION or the current owner.
Also records usage into the active run budget (Contract 6 & DEEP-09)."
  (setq session (or session (kargu-session-context)))
  (when-let* ((usage (kargu-aget response "usage")))
    (let ((in (kargu-aget usage "prompt_tokens"))
          (out (kargu-aget usage "completion_tokens")))
      (when-let* ((app (ignore-errors (kargu-application-context)))
                  (budget (and (kargu-application-p app) (kargu-application-budget app))))
        (kargu-budget-record-tokens budget (and (numberp in) in) (and (numberp out) out)))
      (kargu-session-record-usage (and (numberp in) in) (and (numberp out) out) session)
      (let ((details (kargu-aget usage "prompt_tokens_details")))
        (kargu-session-record-cache-usage in (kargu-aget details "cached_tokens")
                                           (kargu-aget details "cache_write_tokens")
                                           :session session))
      (when (fboundp 'kargu-state-notify-tokens)
        (kargu-state-notify-tokens session))
      (force-mode-line-update t)
      (kargu-log 'info "usage: %s in / %s out (session: %s)"
                 in out (kargu-session-usage session))))
  (kargu-session-snapshot session))

(provide 'kargu/api/client)

;;; client.el ends here
