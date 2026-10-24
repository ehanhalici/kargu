;;; http.el --- Owned Rust chat delivery, budget and retry facade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Asynchronous HTTP for chat completions.  Retry on 429/5xx with a
;; 0.5s floor.  Enforces provider-scoped circuit breakers, unified run
;; budget accounting, and single logical request handle ownership.
;; Public internals used by `kargu/api': `kargu--api-post',
;; `kargu-busy-p', `kargu-api-cancel'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract/constants)
(require 'kargu/contract/result)
(require 'kargu/application/coordinator)
(require 'kargu/application/budget)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/wire)
(require 'kargu/api/circuit)
(require 'kargu/api/request)
(require 'kargu/api/retry)
(require 'kargu/api/transport)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu-provider-format-headers "kargu/providers/registry" (format))
(declare-function kargu--provider-name "kargu/config/key" ())

;;;; Asynchronous request plumbing ----------------------------------------

(defvar kargu--busy nil
  "Non-nil while a chat request is in flight.")

(defvar kargu-api-timeout)
(defvar kargu-api-stall-timeout)
(defvar kargu-api-stream-ceiling)

(defvar kargu--current-process nil
  "Owned Rust delivery handle for the in-flight chat request.")

(defvar kargu--generation 0
  "Request generation counter.
Every request captures the current generation; when a request is
cancelled the counter is bumped and the stale process callbacks
become no-ops.  OS/network resources are owned by Rust.")

(autoload 'kargu-api-cancel "kargu/api/client" nil t)
(autoload 'kargu-api-clear-busy "kargu/api/client")

(defun kargu-busy-p ()
  "Return non-nil while a chat request is in flight."
  (or (and (null (or kargu-application--bound kargu-application-owner)) kargu--busy)
      (kargu-logical-request-live-p
       (kargu-application-current-request) (kargu-application-current-generation))))

(defun kargu-http-request-scope (&optional generation)
  "Return the captured circuit scope for GENERATION, or the legacy default."
  (let ((request (kargu-application-current-request)))
    (if (and request
             (or (null generation)
                 (= generation (kargu-logical-request-generation request))))
        (or (kargu-logical-request-circuit-scope request) "default")
      "default")))

(defun kargu-http-request-budget (&optional generation)
  "Return GENERATION's captured run budget, or the current application budget."
  (let ((request (kargu-application-current-request)))
    (if (and request
             (or (null generation)
                 (= generation (kargu-logical-request-generation request))))
        (kargu-logical-request-budget request)
      (kargu-application-budget-get))))

(defun kargu-http--ensure-logical-request (gen &optional session origin)
  "Return or create the owned `kargu-logical-request' for GEN.
SESSION and ORIGIN identify the request owner when starting a turn."
  (let ((current (kargu-application-current-request)))
    (if (and (kargu-logical-request-p current)
             (= (kargu-logical-request-generation current) gen)
             (not (eq (kargu-logical-request-state current) :cancelled)))
        current
      (let ((created (kargu-logical-request-create
                      :generation gen
                      :session (or session (kargu-session-context))
                      :origin (or origin (current-buffer))
                      :circuit-scope (kargu--provider-name)
                      :budget (kargu-application-budget-get)
                      :app (kargu-application-context)
                      :claim (kargu-application-active-claim-token (kargu-application-context))
                      :state :in-flight)))
        (kargu-application-set-active-request created)
        (when (or session origin) (kargu-http--attach-owner created))
        created))))

(defun kargu-http--attach-owner (request)
  "Attach REQUEST's cancellation to its captured origin, not a global request."
  (let ((app (kargu-logical-request-app request))
        (origin (kargu-logical-request-origin request)))
    (when (buffer-live-p origin)
      (let ((cleanup (kargu-application-wrap
                      app (lambda ()
                            (when (eq request (kargu-application-current-request app))
                              (kargu-http-cancel))))))
        (setf (kargu-logical-request-owner-cleanup request) cleanup)
        (with-current-buffer origin
          (add-hook 'kill-buffer-hook cleanup nil t)
          (add-hook 'change-major-mode-hook cleanup nil t))))))

(defun kargu-http-clear-busy ()
  "Release transport busy/probe ownership without changing application state."
  (let ((scope (kargu-http-request-scope))
        (owned (kargu-application-current-request)))
    (when-let* ((req (kargu-application-current-request)))
      (when (= (kargu-logical-request-generation req) (kargu-application-current-generation))
        (kargu-logical-request-finish req)
        (kargu-application-set-active-request nil)))
    (setq kargu--busy nil)
    (when (or owned (null kargu-application--bound))
      (kargu-circuit-release-probe scope))))

(defun kargu-http-cancel ()
  "Cancel transport resources and invalidate stale request generations.
Application status, loop ownership and UI belong to the caller."
  (let ((req (kargu-application-current-request))
        (scope (kargu-http-request-scope)))
    (when (or req (null kargu-application--bound))
      (kargu-application-next-generation)
      (kargu-circuit-release-probe scope)

      (when req
        (kargu-logical-request-cancel req)
        (when (eq (kargu-application-current-request) req)
          (kargu-application-set-active-request nil)))
      (unless (or kargu-application--bound kargu-application-owner)
        (kargu-transport-cancel kargu--current-process)
        (when (and (processp kargu--current-process)
                   (process-live-p kargu--current-process))
          (ignore-errors (delete-process kargu--current-process))))
      (setq kargu--current-process nil)
      (setq kargu--busy nil)
      (kargu-log 'warn "request cancelled"))))

(defun kargu--api-post (url headers payload gen callback &optional on-delta attempt)
  "POST PAYLOAD to URL with HEADERS and dispatch the result to CALLBACK.
GEN is the cancellation generation.  ON-DELTA enables SSE streaming;
ATTEMPT is the zero-based retry count.
Enforces provider circuit breakers and unified run budget (Contract 6)."
  (cl-block kargu--api-post
    (let* ((attempt (or attempt 0))
           (_logical (kargu-http--ensure-logical-request gen))
           (scope (kargu-http-request-scope gen))
           (budget (kargu-http-request-budget gen)))
      ;; 1. Circuit breaker gate
      (unless (or (> attempt 0)
                  (kargu-circuit-allow-request-p scope))
        (kargu-http-clear-busy)
        (let ((err-msg (format "Circuit breaker OPEN: upstream provider degraded; %s"
                               (kargu-circuit-status-string scope))))
          (kargu-log 'warn "%s" err-msg)
          (funcall callback (kargu-err err-msg :connection-failed
                                       (list :scope scope :side-effect :none))))
        (cl-return-from kargu--api-post nil))

      ;; 2. Run budget debit gate (Contract 6 & DEEP-09)
      (when budget
        (let* ((debit-type (if (> attempt 0) :retry-attempt :normal-request))
               (debit-res (kargu-budget-debit budget debit-type :requests 1)))
          (when (kargu-err-p debit-res)
            (kargu-http-clear-busy)
            (kargu-log 'warn "Run budget exhausted; refusing request (%s)"
                       (kargu-result-err-message debit-res))
            (funcall callback debit-res)
            (cl-return-from kargu--api-post nil))))

      (if (and on-delta kargu-stream)
          (kargu--api-post-streaming url headers payload gen callback
                                     on-delta attempt)
        (kargu--api-post-plain url headers payload gen callback
                               on-delta attempt)))))

(cl-defstruct (kargu-http--request (:constructor kargu-http--make-request))
  "One HTTP attempt and its asynchronous resources."
  url headers payload generation callback on-delta attempt process
  (app (and (kargu-application-current-request) (kargu-application-context)))
  (logical (kargu-application-current-request))
  (state :pending))

(defun kargu-http--wrap (request function)
  "Capture REQUEST's application for FUNCTION; retain bare legacy fixtures."
  (let* ((logical (kargu-http--request-logical request))
         (snapshot (and logical (kargu-logical-request-connection logical)))
         (wrapped (if snapshot
                      (lambda (&rest args)
                        (apply #'kargu-connection-call snapshot function args))
                    function)))
    (if-let* ((app (kargu-http--request-app request)))
        (kargu-application-wrap app wrapped)
      wrapped)))

(defun kargu-http--live-request-p (request)
  "Return non-nil when REQUEST is pending in the current generation."
  (let ((logical (kargu-http--request-logical request))
        (app (kargu-http--request-app request)))
    (and (eq (kargu-http--request-state request) :pending)
         (= (kargu-http--request-generation request) (kargu-application-current-generation app))
         (or (null logical)
             (and (eq logical (kargu-application-current-request app))
                  (kargu-logical-request-current-p logical))))))

(defun kargu-http--claim-response (request)
  "Claim REQUEST once if its generation is still current."
  (when (kargu-http--live-request-p request)
    (setf (kargu-http--request-state request) :finished)
    (when (eq kargu--current-process (kargu-http--request-process request))
      (setq kargu--current-process nil))
    (when-let* ((logical (kargu-http--request-logical request)))
      (when (eq (kargu-logical-request-process logical)
                (kargu-http--request-process request))
        (setf (kargu-logical-request-process logical) nil
              (kargu-logical-request-stream-timer logical) nil)))
    t))

(defun kargu-http--release-process (request)
  "Stop REQUEST's process and watch without touching a newer request."
  (let ((process (kargu-http--request-process request)))
    (kargu-transport-cancel process)
    (when (eq kargu--current-process process)
      (setq kargu--current-process nil))
    (when-let* ((logical (kargu-http--request-logical request)))
      (when (eq (kargu-logical-request-process logical) process)
        (setf (kargu-logical-request-process logical) nil
              (kargu-logical-request-stream-timer logical) nil)))
    (when (and (processp process) (process-live-p process))
      (delete-process process))))

(defun kargu-http--track-process (request process)
  "Publish PROCESS only while REQUEST is live; return it if published."
  (setf (kargu-http--request-process request) process)
  (cond
   ((kargu-http--live-request-p request)
    (let ((logical (or (kargu-http--request-logical request)
                       (kargu-http--ensure-logical-request
                        (kargu-http--request-generation request)))))
      (setf (kargu-logical-request-process logical) process
            (kargu-logical-request-state logical) :in-flight)
      (kargu-logical-request-add-cleanup logical (lambda () (kargu-transport-cancel process))))
    (setq kargu--current-process process))
   (t
    (setf (kargu-http--request-state request) :finished)
    (kargu-http--release-process request)
    nil)))

(defun kargu-http--log-request (request transport)
  "Log REQUEST metadata and its TRANSPORT without credentials."
  (kargu-log 'request "POST model API (model=%s, %d messages, %d tools, %s%s)"
             (kargu--model)
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
     (kargu-http--request-attempt request))))

(defun kargu-http--finish-plain (request body)
  "Deliver BODY for a current, unfinished plain REQUEST."
  (when (kargu-http--claim-response request)
    (kargu-http--handle-body request body)))

(defun kargu-http--fail-request (request err)
  "Deliver sanitized ERR for the current REQUEST, retaining retry ownership."
  (when (kargu-http--claim-response request)
    (kargu--api-on-transport-error
     (kargu-http--request-url request) (kargu-http--request-headers request)
     (kargu-http--request-payload request) (kargu-http--request-generation request)
     (kargu-http--request-callback request) (kargu-http--request-on-delta request)
     (kargu-http--request-attempt request) err)))

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
     request (kargu-transport-request 'post url
                  :headers headers :body (kargu-json-encode-record payload)
                  :as 'string :timeout kargu-api-timeout
                  :then (kargu-http--wrap request
                                          (lambda (body) (kargu-http--finish-plain request body)))
                  :else (kargu-http--wrap request
                                          (lambda (err) (kargu-http--fail-request request err)))))))

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
  "Start REQUEST's Rust stream; Elisp only forwards owned presentation events."
  (kargu-http--track-process
   request
   (kargu-transport-request
    'post (kargu-http--request-url request)
    :headers (kargu-http--request-headers request)
    :body (kargu-json-encode-record
           (append (kargu-http--request-payload request) '(("stream" . t))))
    :as 'string :timeout nil :stream t
    :on-delta (kargu-http--wrap request (kargu-http--live-delta request))
    :then (kargu-http--wrap request (lambda (body) (kargu-http--finish-plain request body)))
    :else (kargu-http--wrap request (lambda (err) (kargu-http--fail-request request err))))))

(defun kargu--api-handle-success (response callback)
  "Record success metrics and dispatch CALLBACK with valid RESPONSE."
  (let ((scope (kargu-http-request-scope)))
    (kargu-http-clear-busy)
    (kargu-circuit-record-success scope)
    (funcall callback response)))

(defun kargu--api-dispatch-error (callback msg)
  "Mark kargu as not busy and invoke CALLBACK with an error alist for MSG.
An upstream-unavailable MSG counts against the circuit breaker here, so
the loop never has to record it again."
  (let ((scope (kargu-http-request-scope)))
    (kargu-http-clear-busy)
    (if (kargu--api-error-looks-retryable-p msg)
        (kargu-circuit-record-failure msg scope)
      (kargu-circuit-release-probe scope))
    (funcall callback (kargu--api-error-alist msg))))

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
                                    on-delta attempt)
  "Decode BODY and deliver its result to CALLBACK.
URL, HEADERS and PAYLOAD retain request data for retries.  GEN identifies
the request, ON-DELTA receives events and ATTEMPT counts retries.
Streaming bodies are already completion-gated and reconstructed by Rust."
  (let* ((trimmed (and (stringp body) (string-trim body)))
         (attempt (or attempt 0)))
    (kargu--log-block "IN HTTP body" (or body "")
                      (kargu--log-looks-json-p trimmed))
    (let* ((response (kargu-api-response-shape
                      (and (stringp body) (kargu--json-decode-safe body))))
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
