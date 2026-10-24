;;; transport.el --- Owned Rust HTTP delivery adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only editor ownership and callback projection live here.  HTTP/TLS/redirects,
;; deadlines, body limits and SSE reconstruction are implemented by Rust.

;;; Code:

(require 'cl-lib)
(require 'plz)
(require 'kargu/bridge)
(require 'kargu/json)
(require 'kargu/core/custom)
(require 'kargu/providers/projection)

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
  connection id startup chunks (bytes 0) (state :pending))

(defun kargu-transport-cancel (handle)
  "Revoke only HANDLE's callbacks and cancel its captured core attempt."
  (when (and (kargu-transport-handle-p handle)
             (eq (kargu-transport-handle-state handle) :pending))
    (setf (kargu-transport-handle-state handle) :cancelled)
    (setf (kargu-transport-handle-chunks handle) nil)
    (when-let* ((cleanup (kargu-transport-handle-startup handle))) (funcall cleanup))
    (setf (kargu-transport-handle-startup handle) nil)
    (when (kargu-transport-handle-id handle)
      (kargu-bridge-cancel (kargu-transport-handle-connection handle)
                           (kargu-transport-handle-id handle)))))

(defun kargu-transport--milliseconds (seconds)
  "Translate positive SECONDS to wire milliseconds, otherwise explicit null."
  (if (and (numberp seconds) (> seconds 0)) (max 1 (ceiling (* seconds 1000))) :json-null))

(defun kargu-transport--error (failure &optional partial)
  "Project sanitized core FAILURE into the current editor error DTO.
PARTIAL prevents retries after any published response event."
  (let* ((code (gethash "code" failure))
         (status (or (gethash "status" failure)
                     (and (member code '("invalid_request" "resource_limit" "cancelled"
                                         "protocol_error" "incomplete_stream" "redirect_refused")) 400)))
         (retry (gethash "retry_after" failure))
         (message (gethash "message" failure "Rust API request failed")))
    (if partial
        (make-plz-error :message "Partial API response failed; automatic replay refused"
                        :response (make-plz-response :status 400 :body ""))
      (make-plz-error
       :message message
       :curl-error (cond ((member code '("deadline" "first_byte_timeout" "idle_timeout")) '(28 . "API timeout"))
                         ((equal code "connection_failed") '(7 . "API connection failed")))
       :response (when (integerp status)
                   (make-plz-response :status status :body ""
                                      :headers (when (stringp retry) (list (cons "retry-after" retry)))))))))

(defun kargu-transport--deliver (handle options result failure)
  "Deliver core RESULT or FAILURE once for HANDLE using captured OPTIONS."
  (when (eq (kargu-transport-handle-state handle) :pending)
    (let ((chunks (kargu-transport-handle-chunks handle)))
      (setf (kargu-transport-handle-state handle) :finished
            (kargu-transport-handle-chunks handle) nil
            (kargu-transport-handle-startup handle) nil)
      (cond
        (failure (funcall (plist-get options :else)
                          ;; Local IPC/admission/consumer failures are not an
                          ;; upstream outage and must not trip its circuit.
                          (make-plz-error :message (gethash "message" failure "Rust API request failed")
                                          :response (make-plz-response :status 400 :body ""))))
       ((not (hash-table-p result))
	(funcall (plist-get options :else) (make-plz-error :message "Invalid Rust API result")))
       ((gethash "failure" result)
	(funcall (plist-get options :else)
		 (kargu-transport--error (gethash "failure" result) (eq (gethash "partial" result) t))))
       ((eq (gethash "body_ready" result) t)
	(let ((body (mapconcat #'identity (nreverse chunks) "")))
          (funcall (plist-get options :then) body)))
       (t (funcall (plist-get options :else) (make-plz-error :message "Invalid Rust API result")))))))

(defun kargu-transport-request (method url &rest options)
  "Send METHOD to captured URL via Rust, returning an owned delivery handle.
OPTIONS contain :headers, :body, :timeout, :stream, :on-delta, :then and :else.
No network request or subprocess is ever started by Elisp."
  (let* ((options (copy-tree options t))
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
                       "deadline_ms" (kargu-transport--milliseconds (if stream kargu-api-stream-ceiling timeout))))))
    ;; copy-tree does not copy mutable strings: copy every authority-bearing
    ;; string before waiting for startup, not only the surrounding cons cells.
    (dolist (pair (plist-get options :headers))
      (puthash (copy-sequence (car pair)) (copy-sequence (cdr pair)) headers))
    (setf (kargu-transport-handle-startup handle)
          (kargu-bridge-ensure
           (lambda (connection failure)
             (when (eq (kargu-transport-handle-state handle) :pending)
               (if (or failure
                       (not (member "api_request" (append (kargu-bridge-connection-capabilities connection) nil)))
                       (and (or (plist-get options :wire) (plist-get options :cache-markers))
                            (not (member "api_wire" (append (kargu-bridge-connection-capabilities connection) nil))))
                       (and (plist-get options :tuning)
                            (not (member "api_request_policy" (append (kargu-bridge-connection-capabilities connection) nil)))))
                   (kargu-transport--deliver handle options nil
                                             (or failure (kargu-bridge--fault "unsupported_api")))
                 (setf (kargu-transport-handle-connection handle) connection
                       (kargu-transport-handle-id handle)
                       (kargu-bridge-call
                        connection "api/request"
                        (kargu-bridge--object "scope" (kargu-bridge-connection-read-scope connection)
                                              "arguments" arguments)
                        (lambda (result error-data) (kargu-transport--deliver handle options result error-data))
                        :owner owner :timeout :unlimited
                        :on-body (lambda (chunk)
                                   (when (eq (kargu-transport-handle-state handle) :pending)
                                     (unless (and (stringp chunk)
                                                  (<= (+ (kargu-transport-handle-bytes handle) (string-bytes chunk))
                                                      (* 8 1024 1024)))
                                       (error "Invalid or oversized core API body"))
                                     (cl-incf (kargu-transport-handle-bytes handle) (string-bytes chunk))
                                     (push chunk (kargu-transport-handle-chunks handle))))
                        :on-delta (lambda (event)
                                    (when (eq (kargu-transport-handle-state handle) :pending)
                                      (when-let* ((delta (plist-get options :on-delta)))
                                        (funcall delta (kargu-json-to-record event))))))))))))
    handle))

(provide 'kargu/api/transport)
;;; transport.el ends here
