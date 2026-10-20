;;; http.el --- plz POST, retry, body handling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Asynchronous HTTP for chat completions.  Retry on 429/5xx with a
;; 0.5s floor.  Public internals used by `kargu/api': `kargu--api-post',
;; `kargu-busy-p', `kargu-api-cancel'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'plz)
(require 'kargu/core)
(require 'kargu/contract/constants)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/wire)
(require 'kargu/api/circuit)
(require 'kargu/api/request)
(require 'kargu/api/retry)
(require 'kargu/api/sse)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu-provider-format-headers "kargu/providers/registry" (format))

;;;; Asynchronous request plumbing ----------------------------------------

(defvar kargu--busy nil
  "Non-nil while a chat request is in flight.")

(defvar kargu-api-timeout)
(defvar kargu-api-stall-timeout)
(defvar kargu-api-stream-ceiling)

(defvar kargu--current-process nil
  "Active plz curl process for the in-flight chat request.")

(defvar kargu--generation 0
  "Request generation counter.
Every request captures the current generation; when a request is
cancelled the counter is bumped and the stale process callbacks
become no-ops.  This gives clean cancellation semantics without
touching plz internals.")

(autoload 'kargu-api-cancel "kargu/api/client" nil t)
(autoload 'kargu-api-clear-busy "kargu/api/client")

(defun kargu-busy-p ()
  "Return non-nil while a chat request is in flight."
  kargu--busy)

(defun kargu-http-clear-busy ()
  "Release transport busy/probe ownership without changing application state."
  (setq kargu--busy nil)
  (kargu-circuit-release-probe))

(defun kargu--api-positive-seconds (value)
  "VALUE when it is a positive number of seconds, otherwise nil."
  (and (numberp value) (> value 0) value))

(defun kargu--api-stream-abort-message (reason)
  "User-facing abort text for stream REASON `stall' or `ceiling'."
  (if (eq reason 'ceiling)
      "stream exceeded ceiling"
    "stream stalled"))

(defun kargu--api-cancel-stream-watch (process)
  "Cancel the stall timer on PROCESS, if any."
  (when (processp process)
    (let ((timer (process-get process :kargu-stream-timer)))
      (when timer
        (cancel-timer timer)
        (process-put process :kargu-stream-timer nil)))))

(defun kargu--api-stream-watch-tick (process)
  "Abort PROCESS when the stream stalls or passes its ceiling."
  (if (not (and (processp process) (process-live-p process)))
      (kargu--api-cancel-stream-watch process)
    (let* ((now (float-time))
           (started (or (process-get process :kargu-stream-started) now))
           (last (or (process-get process :kargu-last-byte) started))
           (stall (kargu--api-positive-seconds
                   (bound-and-true-p kargu-api-stall-timeout)))
           (ceiling (kargu--api-positive-seconds
                     (bound-and-true-p kargu-api-stream-ceiling)))
           (reason (cond
                    ((and ceiling (>= (- now started) ceiling)) 'ceiling)
                    ((and stall (>= (- now last) stall)) 'stall))))
      (when reason
        (process-put process :kargu-stream-abort reason)
        (kargu--api-cancel-stream-watch process)
        (kargu-log 'warn "stream abort: %s" (kargu--api-stream-abort-message reason))
        (ignore-errors (delete-process process))))))

(defun kargu--api-arm-stream-watch (process)
  "Start the stall and ceiling watch for streaming PROCESS."
  (when (processp process)
    (let ((now (float-time)))
      (process-put process :kargu-stream-started now)
      (process-put process :kargu-last-byte now)
      (process-put process :kargu-stream-abort nil)
      (kargu--api-cancel-stream-watch process)
      (process-put process :kargu-stream-timer
                   (run-at-time 1 1 #'kargu--api-stream-watch-tick process)))))

(defun kargu--api-fail-stream (gen reason callback)
  "Fail generation GEN with stream REASON and invoke CALLBACK."
  (when (and callback (= gen kargu--generation))
    (setq kargu--busy nil)
    (let ((msg (kargu--api-stream-abort-message reason)))
      (kargu-circuit-record-failure msg)
      (kargu-log 'error "request failed: %s" msg)
      (funcall callback (kargu--api-error-alist msg)))))

(defun kargu-http-cancel ()
  "Cancel transport resources and invalidate stale request generations.
Application status, loop ownership and UI belong to the caller."
  (cl-incf kargu--generation)
  (kargu-circuit-release-probe)
  (kargu--api-cancel-stream-watch kargu--current-process)
  (when (and (processp kargu--current-process)
             (process-live-p kargu--current-process))
    (ignore-errors (delete-process kargu--current-process)))
  (setq kargu--current-process nil)
  (setq kargu--busy nil)
  (kargu-log 'warn "request cancelled"))

(defun kargu--api-post (url headers payload gen callback &optional on-delta attempt)
  "POST PAYLOAD to URL with HEADERS and dispatch the result to CALLBACK.
GEN is the cancellation generation.  ON-DELTA enables SSE streaming;
ATTEMPT is the zero-based retry count."
  (cl-block kargu--api-post
    (unless (or (and attempt (> attempt 0))
                (kargu-circuit-allow-request-p))
      (setq kargu--busy nil)
      (let ((err-msg (format "Circuit breaker OPEN: upstream provider degraded; %s"
                             (kargu-circuit-status-string))))
        (kargu-log 'warn "%s" err-msg)
        (funcall callback (kargu--api-error-alist err-msg)))
      (cl-return-from kargu--api-post nil))
    (let ((attempt (or attempt 0)))
      (if (and on-delta kargu-stream)
          (kargu--api-post-streaming url headers payload gen callback
                                     on-delta attempt)
        (kargu--api-post-plain url headers payload gen callback
                               on-delta attempt)))))

(cl-defstruct (kargu-http--request (:constructor kargu-http--make-request))
  "One HTTP attempt and its asynchronous resources."
  url headers payload generation callback on-delta attempt process events
  (state :pending))

(defun kargu-http--live-request-p (request)
  "Return non-nil when REQUEST is pending in the current generation."
  (and (eq (kargu-http--request-state request) :pending)
       (= (kargu-http--request-generation request) kargu--generation)))

(defun kargu-http--claim-response (request)
  "Claim REQUEST once if its generation is still current."
  (when (kargu-http--live-request-p request)
    (setf (kargu-http--request-state request) :finished)
    (setq kargu--current-process nil)
    t))

(defun kargu-http--release-process (request)
  "Stop REQUEST's process and watch without touching a newer request."
  (let ((process (kargu-http--request-process request)))
    (kargu--api-cancel-stream-watch process)
    (when (eq kargu--current-process process)
      (setq kargu--current-process nil))
    (when (and (processp process) (process-live-p process))
      (delete-process process))))

(defun kargu-http--track-process (request process)
  "Publish PROCESS only while REQUEST is live; return it if published."
  (setf (kargu-http--request-process request) process)
  (cond
   ((kargu-http--live-request-p request)
    (setq kargu--current-process process))
   (t
    (setf (kargu-http--request-state request) :finished)
    (kargu-http--release-process request)
    nil)))

(defun kargu-http--watch-stream (request)
  "Arm REQUEST's watch, cleaning up and reporting a local startup failure."
  (let ((failure (condition-case err
                     (progn
                       (kargu--api-arm-stream-watch
                        (kargu-http--request-process request))
                       nil)
                   (error err))))
    (when failure
      (let ((deliver (kargu-http--claim-response request)))
        (setf (kargu-http--request-state request) :finished)
        (kargu-http--release-process request)
        (when deliver
          (kargu-http-clear-busy)
          (funcall (kargu-http--request-callback request)
                   (kargu--api-error-alist
                    (format "Stream watchdog startup failed: %s"
                            (error-message-string failure)))))))))

(defun kargu-http--log-request (request transport)
  "Log REQUEST metadata and its TRANSPORT without credentials."
  (kargu-log 'request "POST %s (model=%s, %d messages, %d tools, %s%s)"
             (kargu-http--request-url request) (kargu--model)
             (length (kargu-aget (kargu-http--request-payload request) "messages"))
             (kargu-registered-tool-count)
             transport
             (if (> (kargu-http--request-attempt request) 0)
                 (format ", retry %d" (kargu-http--request-attempt request))
               ""))
  (kargu--log-out-payload
   (if (eq transport 'streaming)
       (append (kargu-http--request-payload request) '(("stream" . t)))
     (kargu-http--request-payload request))))

(defun kargu-http--handle-body (request body)
  "Decode BODY and deliver the response for REQUEST."
  (save-match-data
    (kargu--api-handle-body
     body (kargu-http--request-callback request)
     (kargu-http--request-url request)
     (kargu-http--request-headers request)
     (kargu-http--request-payload request)
     (kargu-http--request-generation request)
     (kargu-http--request-on-delta request)
     (kargu-http--request-attempt request)
     (nreverse (kargu-http--request-events request)))))

(defun kargu-http--finish-plain (request body)
  "Deliver BODY for a current, unfinished plain REQUEST."
  (when (kargu-http--claim-response request)
    (kargu-http--handle-body request body)))

(defun kargu-http--finish-stream (request body)
  "Finish REQUEST's stream and deliver BODY once."
  (kargu--api-cancel-stream-watch (kargu-http--request-process request))
  (when (kargu-http--live-request-p request)
    (kargu--stream-flush
     (kargu-http--request-process request)
     (kargu-http--live-delta request)
     (lambda (event) (push event (kargu-http--request-events request))))
    (when (kargu-http--claim-response request)
      (kargu-http--handle-body request body))))

(defun kargu-http--fail-request (request err)
  "Release REQUEST's watch and report or retry transport failure ERR."
  (save-match-data
    (let* ((process (kargu-http--request-process request))
           (reason (and (processp process)
                        (process-get process :kargu-stream-abort))))
      (kargu--api-cancel-stream-watch process)
      (when (kargu-http--claim-response request)
        (if reason
            (kargu--api-fail-stream
             (kargu-http--request-generation request) reason
             (kargu-http--request-callback request))
          (kargu--api-on-transport-error
           (kargu-http--request-url request)
           (kargu-http--request-headers request)
           (kargu-http--request-payload request)
           (kargu-http--request-generation request)
           (kargu-http--request-callback request)
           (kargu-http--request-on-delta request)
           (kargu-http--request-attempt request) err))))))

(defun kargu-http--live-delta (request)
  "Return a callback forwarding deltas only while REQUEST is live."
  (lambda (event)
    (when (kargu-http--live-request-p request)
      (when-let* ((on-delta (kargu-http--request-on-delta request)))
        (funcall on-delta event)))))

(defun kargu--api-post-plain (url headers payload gen callback &optional on-delta attempt)
  "POST PAYLOAD to URL with HEADERS and deliver it to CALLBACK.
GEN identifies the request; ON-DELTA and ATTEMPT are retained for retries."
  (let ((request (kargu-http--make-request
                  :url url :headers headers :payload payload :generation gen
                  :callback callback :on-delta on-delta :attempt (or attempt 0))))
    (kargu-http--log-request request 'plain)
    (kargu-http--track-process
     request (plz 'post url
               :headers headers :body (kargu-json-encode-record payload)
               :as 'string :timeout kargu-api-timeout
               :then (lambda (body) (kargu-http--finish-plain request body))
               :else (lambda (err) (kargu-http--fail-request request err))))))

(defun kargu--api-post-streaming (url headers payload gen callback on-delta
                                      &optional attempt)
  "Stream PAYLOAD to URL with HEADERS for request generation GEN.
Deliver events to ON-DELTA and the final response to CALLBACK.
ATTEMPT is the retry count."
  (let ((request (kargu-http--make-request
                  :url url :headers headers
                  :payload payload :generation gen
                  :callback callback :on-delta on-delta :attempt (or attempt 0))))
    (kargu-http--log-request request 'streaming)
    (kargu-http--start-stream request)))

(defun kargu-http--start-stream (request)
  "Start REQUEST's streaming process and its stall watch."
  (let* ((on-delta (kargu-http--live-delta request))
         (on-event (lambda (event)
                     (push event (kargu-http--request-events request))))
         (process
          (plz 'post (kargu-http--request-url request)
               :headers (kargu-http--request-headers request)
               :body (kargu-json-encode-record
                      (append (kargu-http--request-payload request)
                              '(("stream" . t))))
               :as 'string :timeout nil
               :filter (lambda (proc string)
                         (kargu--stream-filter proc string on-delta on-event))
               :then (lambda (body) (kargu-http--finish-stream request body))
               :else (lambda (err) (kargu-http--fail-request request err)))))
    (when (kargu-http--track-process request process)
      (kargu-http--watch-stream request))))

(defun kargu--api-decode-body-response (body trimmed parsed-events)
  "Decode HTTP BODY using TRIMMED text or PARSED-EVENTS."
  (cond
   (parsed-events
    (kargu--accumulate-stream-deltas parsed-events))
   ((or (null trimmed) (string-empty-p trimmed)) nil)
   ((string-prefix-p "{" trimmed)
    (kargu--json-decode-safe body))
   ((string-match-p "\\`\\(?:[^\n]*\n\\)*data:" trimmed)
    (let ((events (kargu--sse-parse body)))
      (if events
          (kargu--accumulate-stream-deltas events)
        `(("error" . (("message" . "SSE body contained no data events")))))))
   (t
    `(("error" . (("message" . ,(truncate-string-to-width trimmed 300))))))))

(defun kargu--api-handle-success (response callback)
  "Record success metrics and dispatch CALLBACK with valid RESPONSE."
  (setq kargu--busy nil)
  (kargu-circuit-record-success)
  (funcall callback response))

(defun kargu--api-dispatch-error (callback msg)
  "Mark kargu as not busy and invoke CALLBACK with an error alist for MSG.
An upstream-unavailable MSG counts against the circuit breaker here, so
the loop never has to record it again."
  (setq kargu--busy nil)
  (if (kargu--api-error-looks-retryable-p msg)
      (kargu-circuit-record-failure msg)
    (kargu-circuit-release-probe))
  (funcall callback (kargu--api-error-alist msg)))

(defun kargu--api-handle-no-choices (response trimmed url headers payload gen
                                              callback on-delta attempt)
  "Handle RESPONSE without choices, using TRIMMED for error details.
Retry URL with HEADERS and PAYLOAD for GEN and ATTEMPT when appropriate.
CALLBACK receives the result; ON-DELTA receives streaming events."
  (let ((parsed (kargu--provider-error-text response)))
    (if (and parsed
             (kargu--api-error-looks-retryable-p parsed)
             (kargu--api-schedule-retry
              url headers payload gen callback on-delta attempt
              (format "HTTP 200: %s" parsed)))
        nil
      (kargu--api-dispatch-error
       callback
       (if parsed
           (format "HTTP 200: %s" parsed)
         (format "HTTP 200: response contained no choices%s"
                 (if (and trimmed (not (string-empty-p trimmed)))
                     (concat ": " (truncate-string-to-width trimmed 200))
                   "")))))))

(defun kargu--api-handle-body (body callback &optional url headers payload gen
                                    on-delta attempt parsed-events)
  "Decode BODY and deliver its result to CALLBACK.
URL, HEADERS and PAYLOAD retain request data for retries.  GEN identifies
the request, ON-DELTA receives events and ATTEMPT counts retries.
PARSED-EVENTS avoids reparsing an already decoded stream."
  (let* ((trimmed (and (stringp body) (string-trim body)))
         (attempt (or attempt 0)))
    (kargu--log-block "IN HTTP body" (or body "")
                      (kargu--log-looks-json-p trimmed))
    (let* ((response (kargu-api-response-shape
                      (kargu--api-decode-body-response body trimmed parsed-events)))
           (err (and response (kargu-response-error-message response))))
      (when (and kargu-log-wire response)
        (kargu--log-block "IN reconstructed JSON"
                          (kargu-json-encode-record response)
                          t))
      (cond
       ((and err
             (kargu--api-error-looks-retryable-p err)
             (kargu--api-schedule-retry
              url headers payload gen callback on-delta attempt
              (format "HTTP 200: %s" err)))
        nil)
       ((null response)
        (kargu--api-dispatch-error
         callback
         (format "HTTP 200: empty or invalid response body: %s"
                 (truncate-string-to-width (or body "") 200))))
       (err
        (kargu--api-dispatch-error
         callback
         (format "HTTP 200: %s" err)))
       ((null (kargu-aget response "choices"))
        (kargu--api-handle-no-choices
         response trimmed url headers payload gen callback on-delta attempt))
       (t
        (kargu--api-handle-success response callback))))))


(provide 'kargu/api/http)

;;; http.el ends here
