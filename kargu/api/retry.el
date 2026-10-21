;;; retry.el --- HTTP error classification and retries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Classify transport failures and schedule bounded asynchronous retries.

;;; Code:

(require 'plz)
(require 'time-date)
(require 'kargu/core)
(require 'kargu/core/observers)
(require 'kargu/application/coordinator)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/api/response)
(require 'kargu/api/circuit)

(defvar kargu--busy)
(defvar kargu--generation)

(defvar kargu-api-retry-hook nil
  "Observers called with GENERATION and ON-DELTA before a request is retried.
ON-DELTA identifies the original event consumer; no request secrets are exposed.")

(declare-function kargu--api-post "kargu/api/http"
                  (url headers payload gen callback &optional on-delta attempt))
(declare-function kargu-http--ensure-logical-request "kargu/api/http"
                  (gen &optional session origin))
(declare-function kargu-http-clear-busy "kargu/api/http" ())

(cl-defun kargu-api--retry-post (generation &key url headers payload callback on-delta attempt)
  "Retry GENERATION's URL with HEADERS and PAYLOAD if it still owns the client.
CALLBACK and ON-DELTA retain their original owner; ATTEMPT counts retries."
  (let ((req (kargu-application-current-request)))
    (when (and (= generation kargu--generation)
               (or (null req)
                   (and (= (kargu-logical-request-generation req) generation)
                        (not (eq (kargu-logical-request-state req) :cancelled)))))
      (when req
        (setf (kargu-logical-request-retry-timer req) nil))
      (kargu-run-observers 'kargu-api-retry-hook generation on-delta)
      (let ((req-after (kargu-application-current-request)))
        (when (and (= generation kargu--generation)
                   (or (null req-after)
                       (and (= (kargu-logical-request-generation req-after) generation)
                            (not (eq (kargu-logical-request-state req-after) :cancelled)))))
          (kargu--api-post url headers payload generation callback on-delta attempt))))))

(defun kargu--summarize-http-body (body &optional status)
  "Human-readable summary of HTTP BODY, prefixed with STATUS when given.
JSON error objects are flattened; HTML and plain text are
collapsed to a single truncated line."
  (let* ((trimmed (and (stringp body) (string-trim body)))
         (parsed (and trimmed
                      (string-prefix-p "{" trimmed)
                      (kargu--json-decode-object trimmed)))
         (detail
          (or (and parsed (kargu--provider-error-text parsed))
              (and trimmed (not (string-empty-p trimmed))
                   (truncate-string-to-width
                    (replace-regexp-in-string "[ \t\n\r]+" " " trimmed)
                    300))
              "no detail")))
    (if status
        (format "HTTP %s: %s" status detail)
      detail)))

(defun kargu--plz-error-message (err)
  "Return a human-readable message for a plz error object ERR.
Includes the HTTP status and a parsed provider error body when
available, instead of dumping raw JSON."
  (condition-case-unless-debug _err
      (let* ((resp (plz-error-response err))
             (status (and resp (plz-response-status resp)))
             (resp-body (and resp (plz-response-body resp)))
             (curl-err (plz-error-curl-error err))
             (detail (cond
                      ((and resp-body (not (string-empty-p resp-body)))
                       (kargu--summarize-http-body resp-body))
                      ((and curl-err (cdr curl-err))
                       (format "curl %s: %s"
                               (car curl-err) (cdr curl-err)))
                      ((plz-error-message err))
                      (t "no detail"))))
        (if status
            (format "HTTP %s: %s" status detail)
          (format "plz error: %s" detail)))
    (error (format "%S" err))))

(defun kargu--plz-http-status (err)
  "Numeric HTTP status from plz error ERR, or nil."
  (ignore-errors
    (let* ((resp (plz-error-response err))
           (status (and resp (plz-response-status resp))))
      (cond
       ((integerp status) status)
       ((stringp status) (string-to-number status))
       (t nil)))))

(defun kargu--plz-header (err name)
  "Value of response header NAME on plz error ERR, or nil."
  (ignore-errors
    (let* ((resp (plz-error-response err))
           (headers (and resp (plz-response-headers resp)))
           (want (downcase name)))
      (cl-dolist (h headers)
        (let ((k (car h)))
          (when (equal want (downcase (if (symbolp k)
                                          (symbol-name k)
                                        (format "%s" k))))
            (cl-return (cdr h))))))))

(defun kargu--api-retry-after-seconds (err)
  "Retry-After delay in seconds from ERR, or nil."
  (save-match-data
    (when-let* ((raw (and err (kargu--plz-header err "retry-after")))
                ((stringp raw)))
      (let* ((value (string-trim raw))
             (seconds
              (if (string-match-p (rx string-start (+ digit) string-end) value)
                  (string-to-number value)
                (condition-case nil
                    (float-time (time-subtract (date-to-time value) (current-time)))
                  (error nil)))))
        (when seconds (max 0 (min kargu-api-retry-after-max seconds)))))))

(defun kargu--api-retryable-p (err)
  "Non-nil when ERR is an HTTP status we retry."
  (memq (kargu--plz-http-status err) kargu-http-retry-statuses))

(defun kargu--api-retry-delay (attempt err)
  "Seconds to wait before retry ATTEMPT (0-based) after ERR.
Never below 0.5s, even when Retry-After is 0."
  (let ((after (kargu--api-retry-after-seconds err))
        (backoff (min 32.0 (* (expt 2.0 attempt)
                              (+ 0.5 (/ (random 1000) 1000.0))))))
    (max 0.5 (float (or after backoff)))))

(defun kargu--log-out-payload (payload)
  "Wire-dump encoded PAYLOAD.  Never logs headers or API keys."
  (when kargu-log-wire
    (kargu--log-block "OUT request JSON"
                      (kargu-json-encode-record payload)
                      t)))

(defun kargu--api-error-looks-retryable-p (message)
  "Return non-nil when MESSAGE indicates a retryable upstream failure."
  (and (stringp message)
       (let ((s (downcase message))
             (retry-alt (mapconcat #'number-to-string kargu-http-retry-statuses "\\|")))
         (or (string-match-p (format "\\[\\(%s\\)\\]" retry-alt) message)
             (string-match-p (format "HTTP \\(%s\\)\\>" retry-alt) message)
             (string-match-p "\\<overloaded\\>" s)
             (string-match-p "temporarily unavailable" s)
             (string-match-p "upstream error" s)))))

(defun kargu--api-schedule-retry (url headers payload gen callback on-delta
                                      attempt reason)
  "Schedule another POST to URL with HEADERS and PAYLOAD.
GEN identifies the request.  CALLBACK receives the result and ON-DELTA
receives events.  ATTEMPT counts retries and REASON explains this retry.
Return non-nil if a retry was scheduled."
  (when (and url
             (natnump kargu-api-retry-max)
             (< attempt kargu-api-retry-max))
    (let* ((delay (kargu--api-retry-delay attempt nil))
           (req (kargu-http--ensure-logical-request gen)))
      (kargu-log 'warn "%s; retry %d/%d in %.1fs"
                 reason (1+ attempt) kargu-api-retry-max delay)
      (kargu-logical-request-set-retry-timer
       req
       (run-at-time delay nil
                    (lambda ()
                      (kargu-api--retry-post
                       gen :url url :headers headers :payload payload :callback callback
                       :on-delta on-delta :attempt (1+ attempt)))))
      t)))

(defun kargu--api-on-transport-error (url headers payload gen callback
                                          on-delta attempt err)
  "Retry URL or report transport error ERR to CALLBACK.
HEADERS and PAYLOAD retain the request; GEN identifies it, ON-DELTA
receives events, and ATTEMPT counts completed retries."
  (when (= gen kargu--generation)
    (when kargu-log-wire
      (let* ((resp (ignore-errors (plz-error-response err)))
             (body (and resp (plz-response-body resp))))
        (when (kargu-nonempty body)
          (kargu--log-block "IN HTTP error body" body
                            (kargu--log-looks-json-p body)))))
    (if (and (natnump kargu-api-retry-max)
             (< attempt kargu-api-retry-max)
             (kargu--api-retryable-p err))
        (let* ((delay (kargu--api-retry-delay attempt err))
               (req (kargu-http--ensure-logical-request gen)))
          (kargu-log 'warn "HTTP %s; retry %d/%d in %.1fs"
                     (or (kargu--plz-http-status err) "?")
                     (1+ attempt) kargu-api-retry-max delay)
          (kargu-logical-request-set-retry-timer
           req
           (run-at-time delay nil
                        (lambda ()
                          (kargu-api--retry-post
                           gen :url url :headers headers :payload payload :callback callback
                           :on-delta on-delta :attempt (1+ attempt))))))
      (kargu-http-clear-busy)
      (let ((msg (kargu--plz-error-message err)))
        (if (or (kargu--api-retryable-p err)
                (null (kargu--plz-http-status err)))
            (kargu-circuit-record-failure msg)
          (kargu-circuit-release-probe))
        (kargu-log 'error "request failed: %s" msg)
        (funcall callback (kargu--api-error-alist msg))))))

(provide 'kargu/api/retry)

;;; retry.el ends here
