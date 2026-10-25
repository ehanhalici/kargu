;;; http.el --- Owned Rust chat delivery, budget and retry facade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Rust owns all HTTP attempts, retry/circuit decisions and budget admission.
;; Elisp captures preferences, delivery ownership and presentation callbacks.
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
(declare-function kargu-provider-extra-auth "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
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

(defun kargu-http--ensure-logical-request (gen &optional session origin debit-kind)
  "Return or create the owned `kargu-logical-request' for GEN.
SESSION and ORIGIN identify the owner; DEBIT-KIND labels the logical turn."
  (let ((current (kargu-application-current-request)))
    (if (and (kargu-logical-request-p current)
             (= (kargu-logical-request-generation current) gen)
             (not (eq (kargu-logical-request-state current) :cancelled)))
        current
      (let* ((shared (kargu-application-budget-get))
             (budget (or shared (kargu-budget-create :run-id (format "request-%d" gen))))
             (created (kargu-logical-request-create
                       :generation gen
                       :session (or session (kargu-session-context))
                       :origin (or origin (current-buffer))
                       :circuit-scope (kargu--provider-name)
                       :budget budget :debit-kind (or debit-kind :normal-request)
                       :app (kargu-application-context)
                       :claim (kargu-application-active-claim-token (kargu-application-context))
                       :state :in-flight)))
        (kargu-application-set-active-request created)
        (unless shared
          (kargu-logical-request-add-cleanup created (lambda () (kargu-budget-seal budget))))
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
  "Release editor delivery ownership without mutating native circuit state."
  (when-let* ((req (kargu-application-current-request)))
    (when (= (kargu-logical-request-generation req) (kargu-application-current-generation))
      (kargu-logical-request-finish req)
      (kargu-application-set-active-request nil)))
  (setq kargu--busy nil))

(defun kargu-http-cancel ()
  "Cancel transport resources and invalidate stale request generations.
Application status, loop ownership and UI belong to the caller."
  (let ((req (kargu-application-current-request)))
    (when (or req (null kargu-application--bound))
      (kargu-application-next-generation)
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

(defun kargu--api-post (url auth payload gen callback &optional on-delta)
  "POST PAYLOAD to URL with AUTH and dispatch the result to CALLBACK.
GEN is the cancellation generation; ON-DELTA enables SSE streaming.
The native owner alone admits, charges, retries and retires physical attempts."
  (kargu-http--ensure-logical-request gen)
  (if (and on-delta kargu-stream)
      (kargu--api-post-streaming url auth payload gen callback on-delta)
    (kargu--api-post-plain url auth payload gen callback on-delta)))

(cl-defstruct (kargu-http--request (:constructor kargu-http--make-request))
  "One logical native exchange and its editor delivery lease."
  url auth payload generation callback on-delta process
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
        (setf (kargu-logical-request-process logical) nil)))
    t))

(defun kargu-http--release-process (request)
  "Stop REQUEST's process and watch without touching a newer request."
  (let ((process (kargu-http--request-process request)))
    (kargu-transport-cancel process)
    (when (eq kargu--current-process process)
      (setq kargu--current-process nil))
    (when-let* ((logical (kargu-http--request-logical request)))
      (when (eq (kargu-logical-request-process logical) process)
        (setf (kargu-logical-request-process logical) nil)))
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
  (kargu-log 'request "POST model API (model=%s, %d messages, %d tools, %s)"
             (kargu--model)
             (length (kargu-aget (kargu-http--request-payload request) "messages"))
             (kargu-registered-tool-count)
             transport)
  (kargu--log-out-payload
   (if (eq transport 'streaming)
       (append (kargu-http--request-payload request) '(("stream" . t)))
     (kargu-http--request-payload request))))

(defun kargu-http--handle-body (request body)
  "Decode BODY and deliver the response for REQUEST."
  (save-match-data
    (kargu--api-handle-body body (kargu-http--request-callback request))))

(defun kargu-http--finish-plain (request body)
  "Deliver BODY for a current, unfinished plain REQUEST."
  (when (kargu-http--claim-response request)
    (kargu-http--handle-body request body)))

(defun kargu-http--fail-request (request err)
  "Deliver terminal typed ERR for the current REQUEST exactly once."
  (when (kargu-http--claim-response request)
    (kargu-http-clear-busy)
    (funcall (kargu-http--request-callback request) err)))

(defun kargu-http--live-delta (request)
  "Return a callback forwarding deltas only while REQUEST is live."
  (lambda (event)
    (when (kargu-http--live-request-p request)
      (when-let* ((on-delta (kargu-http--request-on-delta request)))
        (funcall on-delta event)))))

(defun kargu--api-post-plain (url auth payload gen callback &optional on-delta)
  "Deliver native plain PAYLOAD at URL with AUTH for GEN to CALLBACK.
ON-DELTA identifies the original UI consumer for native retry observations."
  (let ((request (kargu-http--make-request
                  :url url :auth auth :payload payload :generation gen
                  :callback callback :on-delta on-delta)))
    (kargu-http--log-request request 'plain)
    (kargu-http--start request nil)))

(defun kargu--api-post-streaming (url auth payload gen callback on-delta)
  "Deliver native streaming PAYLOAD at URL with AUTH for GEN.
CALLBACK receives the terminal result and ON-DELTA receives owned UI events."
  (let ((request (kargu-http--make-request
                  :url url :auth auth :payload payload :generation gen
                  :callback callback :on-delta on-delta)))
    (kargu-http--log-request request 'streaming)
    (kargu-http--start request t)))

(defun kargu-http--observe-retry (request _observation)
  "Notify REQUEST's captured UI consumer before the native retry ACK."
  (unless (kargu-http--live-request-p request) (error "Obsolete API retry owner"))
  (kargu-run-observers 'kargu-api-retry-hook
                       (kargu-http--request-generation request)
                       (kargu-http--request-on-delta request))
  ;; A hook may cancel, replace the owner or change generation reentrantly.
  ;; Throwing refuses the reverse ACK; it never creates another forward call.
  (unless (kargu-http--live-request-p request) (error "Revoked API retry owner")))

(defun kargu-http--start (request stream)
  "Start REQUEST's logical native exchange, optionally with STREAM delivery."
  (kargu-http--track-process
   request
   (kargu-transport-request
    'post (kargu-http--request-url request)
    :application (or (kargu-http--request-app request) (kargu-application-context))
    :budget (kargu-http-request-budget (kargu-http--request-generation request))
    :debit-kind (if-let* ((logical (kargu-http--request-logical request)))
                    (kargu-logical-request-debit-kind logical) :normal-request)
    :retry (kargu-api-retry-preferences)
    :circuit (kargu-circuit-preferences)
    :on-retry (kargu-http--wrap request (lambda (observation)
                                        (kargu-http--observe-retry request observation)))
    :auth (kargu-http--request-auth request)
    :wire (kargu-api-wire-record (kargu-api-active-format))
    :tuning (kargu-api-request-tuning (kargu--provider-name) (kargu--model))
    :provider (kargu-http-request-scope (kargu-http--request-generation request))
    :cache-markers (if (kargu-connection-current)
                       (kargu-connection-setting :cache-marker)
                     (kargu-provider-cache-marker-p (kargu--provider-name)))
    :body (kargu-json-encode-record
           (if stream (append (kargu-http--request-payload request) '(("stream" . t)))
             (kargu-http--request-payload request)))
    :as 'string :timeout (unless stream kargu-api-timeout) :stream stream
    :on-delta (when stream (kargu-http--wrap request (kargu-http--live-delta request)))
    :then (kargu-http--wrap request (lambda (body) (kargu-http--finish-plain request body)))
    :else (kargu-http--wrap request (lambda (err) (kargu-http--fail-request request err))))))

(defun kargu--api-handle-body (body callback)
  "Decode native canonical BODY for CALLBACK; never infer replay from prose.
Rust has already validated the terminal completion.  Invalid editor delivery
is a protocol failure, not a reason to open another socket."
  (let ((response (and (stringp body) (kargu--json-decode-safe body))))
    (kargu--log-block "IN HTTP body" (or body "") (kargu--log-looks-json-p body))
    (kargu-http-clear-busy)
    (funcall callback
             (if (and response (kargu-aget response "choices")
                      (not (kargu-response-error-message response)))
                 response
               (kargu-err "Invalid native API completion" :protocol-error)))))

(provide 'kargu/api/http)
;;; http.el ends here
