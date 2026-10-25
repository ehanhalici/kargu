;;; transport.el --- Owned Rust HTTP delivery adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only editor ownership and callback projection live here.  HTTP/TLS/redirects,
;; deadlines, body limits and SSE reconstruction are implemented by Rust.

;;; Code:

(require 'cl-lib)
(require 'kargu/api/failure)
(require 'kargu/bridge)
(require 'kargu/json)
(require 'kargu/core/custom)
(require 'kargu/providers/projection)
(require 'kargu/bridge/application)
(require 'kargu/bridge/budget)
(require 'kargu/bridge/circuit)

(defvar kargu-api-timeout)
(defvar kargu-api-connect-timeout)
(defvar kargu-api-first-byte-timeout)
(defvar kargu-api-stall-timeout)
(defvar kargu-api-stream-ceiling)
(defvar kargu-stream-max-raw-bytes)
(defvar kargu-stream-max-incomplete-line-bytes)
(defvar kargu-sse-max-event-bytes)
(defvar kargu-stream-max-tool-calls)
(defvar kargu-stream-max-tool-args-bytes)

(cl-defstruct (kargu-transport-handle (:constructor kargu-transport--handle))
  "An editor delivery lease, not an OS process."
  connection id native-scope startup chunks owner owner-cleanup (bytes 0) (state :pending))

(defun kargu-transport--detach-owner (handle)
  "Detach HANDLE's startup and delivery lifecycle hooks exactly once."
  (when-let* ((cleanup (kargu-transport-handle-owner-cleanup handle)))
    (setf (kargu-transport-handle-owner-cleanup handle) nil)
    (when (buffer-live-p (kargu-transport-handle-owner handle))
      (with-current-buffer (kargu-transport-handle-owner handle)
        (remove-hook 'kill-buffer-hook cleanup t)
        (remove-hook 'change-major-mode-hook cleanup t)))))

(defun kargu-transport--drain-startup (handle)
  "Release HANDLE's independently acquired startup waiters once."
  (let ((cleanups (kargu-transport-handle-startup handle)))
    (setf (kargu-transport-handle-startup handle) nil)
    (dolist (cleanup cleanups)
      (condition-case nil (funcall cleanup)
        ((error quit) (message "Kargu API startup cleanup failed"))))))

(defun kargu-transport-cancel (handle)
  "Revoke only HANDLE's callbacks and cancel its captured core attempt."
  (when (and (kargu-transport-handle-p handle)
             (eq (kargu-transport-handle-state handle) :pending))
    (setf (kargu-transport-handle-state handle) :cancelled)
    (kargu-transport--detach-owner handle)
    (setf (kargu-transport-handle-chunks handle) nil)
    (kargu-transport--drain-startup handle)
    (when (kargu-transport-handle-id handle)
      (kargu-bridge-cancel (kargu-transport-handle-connection handle)
                           (kargu-transport-handle-id handle)))))

(defun kargu-transport--milliseconds (seconds)
  "Translate positive SECONDS to wire milliseconds, otherwise explicit null."
  (if (and (numberp seconds) (> seconds 0)) (max 1 (ceiling (* seconds 1000))) :json-null))

(defun kargu-transport--deliver (handle options result failure)
  "Deliver core RESULT or FAILURE once for HANDLE using captured OPTIONS."
  (when (eq (kargu-transport-handle-state handle) :pending)
    (when-let* ((snapshot (and (hash-table-p result) (gethash "circuit" result)))
                ((kargu-bridge-circuit-current-p
                  (plist-get options :application) (kargu-transport-handle-connection handle)
                  (kargu-transport-handle-native-scope handle))))
      (condition-case nil
          (kargu-bridge-circuit-observe
           (plist-get options :application) (kargu-transport-handle-connection handle)
           (kargu-transport-handle-native-scope handle) snapshot t)
        (error (setq failure (kargu-bridge--fault "invalid_circuit_projection")))))
    (when-let* ((budget (plist-get options :budget)))
      (condition-case nil
          (when-let* ((snapshot (and (hash-table-p result) (gethash "budget" result))))
            (kargu-bridge-budget-observe budget snapshot))
        (error (setq failure (kargu-bridge--fault "invalid_budget_projection"))))
      (when (and (hash-table-p failure)
                 (equal (gethash "status" (gethash "data" failure)) "budget_exhausted"))
        (setf (kargu-run-budget-status budget) :budget-exhausted)))
    (let ((chunks (kargu-transport-handle-chunks handle)))
      (setf (kargu-transport-handle-state handle) :finished
            (kargu-transport-handle-chunks handle) nil)
      (kargu-transport--drain-startup handle)
      (kargu-transport--detach-owner handle)
      (cond
       (failure (funcall (plist-get options :else) (kargu-api-failure-ipc-result failure)))
       ((not (hash-table-p result))
	(funcall (plist-get options :else) (kargu-err "Invalid Rust API result" :protocol-error)))
       ((gethash "failure" result)
	(funcall (plist-get options :else)
		 (kargu-api-failure-result (gethash "failure" result) (eq (gethash "partial" result) t))))
       ((eq (gethash "body_ready" result) t)
	(let ((body (mapconcat #'identity (nreverse chunks) "")))
          (funcall (plist-get options :then) body)))
       (t (funcall (plist-get options :else) (kargu-err "Invalid Rust API result" :protocol-error)))))))

(defun kargu-transport--startup (handle cleanup)
  "Attach startup CLEANUP to HANDLE or release an acquisition delivered late."
  (if (eq (kargu-transport-handle-state handle) :pending)
      (push cleanup (kargu-transport-handle-startup handle))
    (funcall cleanup)))

(defun kargu-transport--post (handle options arguments connection scope failure)
  "Send captured ARGUMENTS on CONNECTION under SCOPE for HANDLE and OPTIONS.
FAILURE ends only this editor delivery."
  (when (eq (kargu-transport-handle-state handle) :pending)
    (cond
     (failure (kargu-transport--deliver handle options nil failure))
     ((not (buffer-live-p (kargu-transport-handle-owner handle))) (kargu-transport-cancel handle))
     ((plist-get options :budget)
      (kargu-transport--startup
       handle (kargu-bridge-budget-ensure
               (plist-get options :budget) connection scope
               (lambda (id error-data)
                 (if error-data (kargu-transport--deliver handle options nil error-data)
                   (kargu-transport--invoke handle options arguments connection scope
                                            (kargu-bridge--object "budget_id" id "kind" (plist-get options :debit-kind))))))))
     (t (kargu-transport--invoke handle options arguments connection scope nil)))))

(defun kargu-transport--invoke (handle options arguments connection scope budget)
  "Invoke native HTTP with captured ARGUMENTS, SCOPE and optional BUDGET reference.
HANDLE and OPTIONS own delivery on CONNECTION."
  (when (eq (kargu-transport-handle-state handle) :pending)
    (let ((params (kargu-bridge--object "scope" scope "arguments" arguments)))
      (when budget (puthash "budget" budget params))
      (when-let* ((policy (plist-get options :retry)))
        (let ((configuration (kargu-bridge--object "policy" policy "observer" "editor")))
          (when-let* ((circuit (plist-get options :circuit))) (puthash "circuit" circuit configuration))
          (puthash "retry" configuration params)))
      (setf (kargu-transport-handle-connection handle) connection
            (kargu-transport-handle-native-scope handle)
            (when (plist-get options :circuit) (kargu-bridge-application--copy-scope scope))
            (kargu-transport-handle-id handle)
            (kargu-bridge-call
             connection "api/request" params
             (lambda (result error-data) (kargu-transport--deliver handle options result error-data))
             :owner (kargu-transport-handle-owner handle) :timeout :unlimited
             :on-retry (when (plist-get options :retry)
                         (lambda (observation)
                           (when-let* ((meter (plist-get options :budget)))
                             (kargu-bridge-budget-observe meter (gethash "budget" observation)))
                           (when-let* ((observer (plist-get options :on-retry)))
                             (funcall observer observation))))
             :on-body (lambda (chunk)
                        (when (eq (kargu-transport-handle-state handle) :pending)
                          (unless (and (stringp chunk)
                                       (<= (+ (kargu-transport-handle-bytes handle) (string-bytes chunk)) (* 8 1024 1024)))
                            (error "Invalid or oversized core API body"))
                          (cl-incf (kargu-transport-handle-bytes handle) (string-bytes chunk))
                          (push chunk (kargu-transport-handle-chunks handle))))
             :on-delta (lambda (event)
                         (when (eq (kargu-transport-handle-state handle) :pending)
                           (when-let* ((delta (plist-get options :on-delta)))
                             (funcall delta (kargu-json-to-record event))))))))))

(defun kargu-transport--ready (handle options arguments connection failure)
  "Advance HANDLE after startup using OPTIONS, ARGUMENTS, CONNECTION and FAILURE."
  (when (eq (kargu-transport-handle-state handle) :pending)
    (let* ((capabilities (and connection (append (kargu-bridge-connection-capabilities connection) nil)))
           (required (plist-get options :required))
           (binding (when-let* ((app (plist-get options :application)))
                      (gethash :native-core (kargu-application-services app)))))
      (cond
       ((or failure (not (cl-every (lambda (capability) (member capability capabilities)) required)))
        (kargu-transport--deliver handle options nil (or failure (kargu-bridge--fault "unsupported_api"))))
       ((and (plist-get options :connection) binding
             (not (eq connection (kargu-bridge-application-connection binding))))
        (kargu-transport--deliver handle options nil (kargu-bridge--fault "owner_closed")))
       ((plist-get options :application)
        (kargu-transport--startup
         handle (kargu-bridge-application-ensure
                 connection (plist-get options :application)
                 (lambda (scope error-data)
                   (kargu-transport--post handle options arguments connection scope error-data)))))
       (t (kargu-transport--post handle options arguments connection
                                 (kargu-bridge-connection-read-scope connection) nil))))))

(defun kargu-transport-request (method url &rest options)
  "Send METHOD to captured URL via Rust, returning an owned delivery handle.
OPTIONS contain captured :auth/:wire/:tuning, :body, :timeout, :stream,
:on-delta, :then and :else; raw :headers are reserved for explicit callers.
:retry captures native policy; :on-retry observes it before native replay ACK.
:circuit captures native policy and requires :application and :retry.
:model-catalog selects native GET-only discovery envelope normalization.
:chat-target derives the chat path from URL as a base inside Rust.
:connection pins an existing native epoch, without startup or reconnect.
No network request or subprocess is ever started by Elisp."
  (let* ((application (plist-get options :application))
         (url (copy-sequence url))
         (handle (kargu-transport--handle))
         (owner (current-buffer))
         (headers (make-hash-table :test #'equal))
         (stream (plist-get options :stream))
         (timeout (plist-get options :timeout))
         (arguments
          (kargu-bridge--object
           "method" (symbol-name method) "url" url "headers" headers
           "body" (if-let* ((body (plist-get options :body))) (copy-sequence body) :json-null)
           "stream" (if stream t :json-false)
           "wire" (kargu-providers-wire-object (plist-get options :wire))
           "provider" (if-let* ((provider (plist-get options :provider)))
                          (copy-sequence provider) :json-null)
           "cache_markers" (if (plist-get options :cache-markers) t :json-false)
           "tuning" (kargu-providers-wire-object (plist-get options :tuning))
           "auth" (kargu-providers-wire-object (plist-get options :auth))
           "limits" (kargu-bridge--object
                     "raw_bytes" kargu-stream-max-raw-bytes
                     "line_bytes" kargu-stream-max-incomplete-line-bytes
                     "event_bytes" kargu-sse-max-event-bytes
                     "tool_calls" kargu-stream-max-tool-calls
                     "argument_bytes" kargu-stream-max-tool-args-bytes)
           "timeouts" (kargu-bridge--object
                       "connect_ms" (kargu-transport--milliseconds kargu-api-connect-timeout)
                       "first_byte_ms" (kargu-transport--milliseconds kargu-api-first-byte-timeout)
                       "idle_ms" (kargu-transport--milliseconds (and stream kargu-api-stall-timeout))
                       "deadline_ms" (kargu-transport--milliseconds (if stream kargu-api-stream-ceiling timeout)))))
         ;; Owner records/closures form cyclic graphs. Preserve their identity;
         ;; copy only DTO authority through the explicit encoders above.
         (delivery-options
          (list :application application :budget (plist-get options :budget)
                :retry (when (plist-get options :retry)
                         (kargu-providers-wire-object (plist-get options :retry)))
                :on-retry (plist-get options :on-retry)
                :circuit (when (plist-get options :circuit)
                           (kargu-providers-wire-object (plist-get options :circuit)))
                :debit-kind (replace-regexp-in-string "-" "_"
                                                      (substring (symbol-name (or (plist-get options :debit-kind) :normal-request)) 1))
                :then (plist-get options :then)
                :else (plist-get options :else) :on-delta (plist-get options :on-delta)
                :connection (plist-get options :connection)
                :required (append '("api_request" "api_failure")
                                  (when (plist-get options :chat-target) '("api_chat_target"))
                                  (when (plist-get options :budget) '("api_budget"))
                                  (when (plist-get options :retry) '("api_retry"))
                                  (when (plist-get options :circuit) '("api_circuit"))
                                  (when (plist-get options :model-catalog) '("api_model_catalog"))
                                  (when (or (not (eq (gethash "wire" arguments) :json-null))
                                            (eq (gethash "cache_markers" arguments) t)) '("api_wire"))
                                  (unless (eq (gethash "tuning" arguments) :json-null) '("api_request_policy"))
                                  (unless (eq (gethash "auth" arguments) :json-null) '("api_auth"))))))
    (when (and (plist-get options :circuit) (not (and application (plist-get options :retry))))
      (error "Native circuit requires an application and retry profile"))
    (when (plist-get options :model-catalog)
      (puthash "response_profile" "model_catalog" arguments))
    (when (plist-get options :chat-target)
      (puthash "target" "chat" arguments))
    ;; copy-tree does not copy mutable strings: copy every authority-bearing
    ;; string before waiting for startup, not only the surrounding cons cells.
    (dolist (pair (plist-get options :headers))
      (puthash (copy-sequence (car pair)) (copy-sequence (cdr pair)) headers))
    (let ((cleanup (lambda () (kargu-transport-cancel handle))))
      (setf (kargu-transport-handle-owner handle) owner
            (kargu-transport-handle-owner-cleanup handle) cleanup)
      (with-current-buffer owner
        (add-hook 'kill-buffer-hook cleanup nil t)
        (add-hook 'change-major-mode-hook cleanup nil t)))
    (if-let* ((connection (plist-get options :connection)))
        (kargu-transport--ready handle delivery-options arguments connection
                                (unless (eq (kargu-bridge-status connection) 'ready)
                                  (kargu-bridge--fault "disconnected")))
      (kargu-transport--startup
       handle (kargu-bridge-ensure
               (lambda (connection failure)
                 (kargu-transport--ready handle delivery-options arguments connection failure)))))
    handle))

(provide 'kargu/api/transport)
;;; transport.el ends here
