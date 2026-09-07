;;; kargu/api/http.el --- plz POST, retry, body handling -*- lexical-binding: t; -*-

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
(require 'kargu/constants)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)

;;;; Asynchronous request plumbing ----------------------------------------

(defvar kargu--busy nil
  "Non-nil while a chat request is in flight.")

(defvar kargu--current-process nil
  "Active plz curl process for the in-flight chat request.")

(defvar kargu--generation 0
  "Request generation counter.
Every request captures the current generation; when a request is
cancelled the counter is bumped and the stale process callbacks
become no-ops.  This gives clean cancellation semantics without
touching plz internals.")

(defun kargu-busy-p ()
  "Return non-nil while a chat request is in flight."
  kargu--busy)

(defun kargu-api-cancel ()
  "Cancel the current request.
Stale response callbacks are turned into no-ops via the
generation counter; the active curl process is terminated and
the UI is left in a consistent state."
  (interactive)
  (cl-incf kargu--generation)
  (when (and (processp kargu--current-process)
             (process-live-p kargu--current-process))
    (ignore-errors (delete-process kargu--current-process)))
  (setq kargu--current-process nil)
  (setq kargu--busy nil)
  (kargu-log 'warn "request cancelled"))

(defun kargu--build-payload (&rest extra)
  "Assemble the chat-completions request payload.
EXTRA is a list of additional (KEY . VALUE) conses appended to
the payload (e.g. (\"stream\" . t)).  The \"tools\" array is only
included when at least one tool is VISIBLE after
`kargu--tools-visible-p' filtering."
  (let* ((tools (kargu--build-tools-vector))
         (payload `(("model" . ,(kargu--model))
                    ("messages" . ,(vconcat kargu--message-history)))))
    (when kargu-temperature
      (nconc payload `(("temperature" . ,kargu-temperature))))
    (when kargu-max-tokens
      (nconc payload `(("max_tokens" . ,kargu-max-tokens)
                       ("max_completion_tokens" . ,kargu-max-tokens))))
    (let ((reasoning-alist nil))
      (when (and (boundp 'kargu-reasoning-effort)
                 kargu-reasoning-effort)
        (let ((effort (cond ((symbolp kargu-reasoning-effort)
                             (symbol-name kargu-reasoning-effort))
                            ((stringp kargu-reasoning-effort)
                             kargu-reasoning-effort))))
          (unless (member effort '("none" "nil" "off"))
            (nconc payload `(("reasoning_effort" . ,effort)))
            (push (cons "effort" effort) reasoning-alist))))
      (when (and (boundp 'kargu-thinking-budget)
                 (integerp kargu-thinking-budget)
                 (> kargu-thinking-budget 0))
        (nconc payload `(("thinking" . (("type" . "enabled")
                                        ("budget_tokens" . ,kargu-thinking-budget)))))
        (push (cons "max_tokens" kargu-thinking-budget) reasoning-alist))
      (when reasoning-alist
        (nconc payload `(("reasoning" . ,(nreverse reasoning-alist))))))
    (when (> (length tools) 0)
      (nconc payload `(("tools" . ,tools)
                       ("tool_choice" . "auto"))))
    (while extra
      (nconc payload (list (pop extra))))
    payload))

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

(defconst kargu--api-retry-statuses
  (or (bound-and-true-p kargu-http-retry-statuses) '(429 500 502 503 529))
  "HTTP statuses that trigger exponential backoff retry.")

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
  (let ((raw (kargu--plz-header err "retry-after")))
    (when (and (stringp raw) (string-match "\\`[0-9]+\\'" (string-trim raw)))
      (max 0 (string-to-number raw)))))

(defun kargu--api-retryable-p (err)
  "Non-nil when ERR is an HTTP status we retry."
  (memq (kargu--plz-http-status err) kargu--api-retry-statuses))

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
                      (kargu--json-encode payload)
                      t)))

(defun kargu--api-error-looks-retryable-p (message)
  "Non-nil when MESSAGE looks like HTTP 429/5xx or provider overload.
HTTP 200 bodies can still carry an SSE `error' event with a 502
or \"overloaded\" text; those are retryable the same way as a
transport-level 502."
  (and (stringp message)
       (let ((s (downcase message)))
         (or (string-match-p "\\[\\(429\\|500\\|502\\|503\\|529\\)\\]" message)
             (string-match-p "HTTP \\(429\\|500\\|502\\|503\\|529\\)\\>" message)
             (string-match-p "\\<overloaded\\>" s)
             (string-match-p "temporarily unavailable" s)
             (string-match-p "upstream error" s)))))

(defun kargu--api-schedule-retry (url headers payload gen callback on-delta
                                    attempt reason)
  "Schedule another POST of PAYLOAD.  Return non-nil if scheduled.
Does not clear `kargu--busy'; the in-flight request stays open
until the retry finishes or is cancelled."
  (when (and url
             (natnump kargu-api-retry-max)
             (< attempt kargu-api-retry-max))
    (let ((delay (kargu--api-retry-delay attempt nil)))
      (kargu-log 'warn "%s; retry %d/%d in %.1fs"
                       reason (1+ attempt) kargu-api-retry-max delay)
      (run-at-time delay nil
                   (lambda ()
                     (when (= gen kargu--generation)
                       (kargu--api-post url headers payload gen
                                        callback on-delta (1+ attempt)))))
      t)))

(defun kargu--api-on-transport-error (url headers payload gen callback
                                         on-delta attempt err)
  "Retry or fail after transport error ERR."
  (when (= gen kargu--generation)
    (when kargu-log-wire
      (let* ((resp (ignore-errors (plz-error-response err)))
             (body (and resp (plz-response-body resp))))
        (when (kargu--nonempty body)
          (kargu--log-block "IN HTTP error body" body
                            (kargu--log-looks-json-p body)))))
    (if (and (natnump kargu-api-retry-max)
             (< attempt kargu-api-retry-max)
             (kargu--api-retryable-p err))
        (let ((delay (kargu--api-retry-delay attempt err)))
          (kargu-log 'warn "HTTP %s; retry %d/%d in %.1fs"
                           (or (kargu--plz-http-status err) "?")
                           (1+ attempt) kargu-api-retry-max delay)
          (run-at-time delay nil
                       (lambda ()
                         (when (= gen kargu--generation)
                           (kargu--api-post url headers payload gen
                                            callback on-delta (1+ attempt))))))
      (setq kargu--busy nil)
      (let ((msg (kargu--plz-error-message err)))
        (kargu-circuit-record-failure msg)
        (kargu-log 'error "request failed: %s" msg)
        (funcall callback (kargu--api-error-alist msg))))))

(defun kargu--api-headers (key &optional provider-name)
  "HTTP headers for the active or specified PROVIDER-NAME.
KEY is the resolved secret.  An empty KEY omits Authorization so
local or keyless proxies still work.  Includes `x-opencode-session'
for OpenCode routing/caching affinity and any provider extra-headers."
  (let* ((sid (if (fboundp 'kargu-session-id) (kargu-session-id) "default"))
         (pname (if provider-name
                    (format "%s" provider-name)
                  (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
         (pname-lower (downcase (string-trim pname)))
         (base (if (fboundp 'kargu--api-base) (kargu--api-base pname-lower) ""))
         (is-opencode (or (string-match-p "opencode" base)
                          (string-match-p "opencode" pname-lower)))
         (is-anthropic (or (string-match-p "anthropic" base)
                           (string-match-p "anthropic" pname-lower)))
         (extra (and (fboundp 'kargu-provider-extra-headers)
                     (kargu-provider-extra-headers pname-lower)))
         (headers
          (append
           `(("Content-Type" . "application/json")
             ("HTTP-Referer" . ,kargu-app-url)
             ("X-Title" . "kargu"))
           (when (kargu--nonempty key)
             (if is-anthropic
                 `(("x-api-key" . ,key)
                   ("anthropic-version" . "2023-06-01"))
               `(("Authorization" . ,(concat "Bearer " key))))))))
    (when (or is-opencode (string-prefix-p "opencode" pname-lower))
      (setq headers (append headers (list (cons "x-opencode-session" sid)))))
    (when (listp extra)
      (setq headers (append headers extra)))
    headers))

(defun kargu--api-post (url headers payload gen callback &optional on-delta attempt)
  "POST PAYLOAD to URL via plz, dispatching to CALLBACK.
GEN is the request generation for cancellation.  When ON-DELTA
is supplied and `kargu-stream' is non-nil, use the SSE
streaming transport; otherwise a single asynchronous request.
ATTEMPT is the 0-based retry count.  Neither transport ever
blocks the UI thread."
  (cl-block kargu--api-post
    (unless (kargu-circuit-allow-request-p)
      (setq kargu--busy nil)
      (let ((err-msg (format "Circuit breaker OPEN: upstream provider degraded; %s"
                             (kargu-circuit-status-string))))
        (kargu-log 'warn "%s" err-msg)
        (funcall callback (kargu--api-error-alist err-msg)))
      (cl-return-from kargu--api-post nil))
    (let ((attempt (or attempt 0)))
      (if (and on-delta kargu-stream)
          (condition-case-unless-debug err
              (kargu--api-post-streaming url headers payload gen callback
                                         on-delta attempt)
            (error
             (kargu-log 'warn "streaming unavailable (%s); using plain request"
                              (error-message-string err))
             (kargu--api-post-plain url headers payload gen callback
                                    on-delta attempt)))
        (kargu--api-post-plain url headers payload gen callback
                               on-delta attempt)))))

(defun kargu--api-post-plain (url headers payload gen callback &optional on-delta attempt)
  "Single asynchronous POST; no streaming."
  (kargu-log 'request "POST %s (model=%s, %d messages, %d tools, plain%s)"
                   url (kargu--model)
                   (length kargu--message-history)
                   (hash-table-count kargu--tool-registry)
                   (if (and attempt (> attempt 0))
                       (format ", retry %d" attempt)
                     ""))
  (kargu--log-out-payload payload)
  (let ((timeout (bound-and-true-p kargu-api-timeout)))
    (setq kargu--current-process
          (apply #'plz 'post url
                 :headers headers
                 :body (kargu--json-encode payload)
                 :as 'string
                 (append
                  (when (numberp timeout) (list :timeout timeout))
                  (list
                   :then (lambda (body)
                           (setq kargu--current-process nil)
                           (when (= gen kargu--generation)
                             (kargu--api-handle-body
                              body callback url headers payload gen on-delta
                              (or attempt 0))))
                   :else (lambda (err)
                           (setq kargu--current-process nil)
                           (kargu--api-on-transport-error
                            url headers payload gen callback on-delta
                            (or attempt 0) err))))))))

(defun kargu--api-post-streaming (url headers payload gen callback on-delta
                                     &optional attempt)
  "Streaming POST: SSE events reach ON-DELTA as they arrive.
The final response is reconstructed directly from the events
accumulated during streaming, eliminating redundant re-parsing
of the entire SSE body text."
  (kargu-log 'request "POST %s (model=%s, %d messages, %d tools, streaming%s)"
                   url (kargu--model)
                   (length kargu--message-history)
                   (hash-table-count kargu--tool-registry)
                   (if (and attempt (> attempt 0))
                       (format ", retry %d" attempt)
                     ""))
  (let* ((stream-payload (append payload '(("stream" . t))))
         (events-acc nil)
         (on-event (lambda (event)
                     (push event events-acc)))
         (timeout (bound-and-true-p kargu-api-timeout)))
    (kargu--log-out-payload stream-payload)
    (setq kargu--current-process
          (apply #'plz 'post url
                 :headers headers
                 :body (kargu--json-encode stream-payload)
                 :as 'string
                 (append
                  (when (numberp timeout) (list :timeout timeout))
                  (list
                   :filter (lambda (process string)
                             (kargu--stream-filter process string on-delta on-event))
                   :then (lambda (body)
                           (setq kargu--current-process nil)
                           (when (= gen kargu--generation)
                             (kargu--api-handle-body
                              body callback url headers payload gen on-delta
                              (or attempt 0) (nreverse events-acc))))
                   :else (lambda (err)
                           (setq kargu--current-process nil)
                           (kargu--api-on-transport-error
                            url headers payload gen callback on-delta
                            (or attempt 0) err))))))))

(defun kargu--stream-filter (process string on-delta &optional on-event)
  "plz process filter for SSE responses.
STRING is raw (unibyte) curl output, including the HTTP headers.
The filter (1) inserts all raw output into the process buffer,
which plz needs for its own response parsing, and (2) scans a
private raw accumulator for complete SSE lines, decoding and
forwarding each data event to ON-DELTA and ON-EVENT.  Lines are only cut at
newline bytes: UTF-8 continuation bytes never contain 0x0A, so a
chunk boundary can never split a character inside a complete
line.  The filter never signals."
  (condition-case-unless-debug err
      (let ((buffer (process-buffer process)))
        (when (buffer-live-p buffer)
          ;; (1) keep plz's view of the response intact
          (with-current-buffer buffer
            (save-excursion
              (goto-char (point-max))
              (insert string)))
          ;; (2) side-channel SSE parsing on raw bytes
          (let* ((raw (concat (or (process-get process :kargu-raw)
                                  "")
                              string))
                 (pos (cl-position ?\n raw :from-end t)))
            (if (null pos)
                (process-put process :kargu-raw raw)
              (let ((complete (decode-coding-string
                               (substring raw 0 (1+ pos)) 'utf-8)))
                (process-put process :kargu-raw (substring raw (1+ pos)))
                (dolist (line (split-string complete "\n" t))
                  (kargu--stream-line process line on-delta on-event)))))))
    (error
     (kargu-log 'error "stream filter error: %s"
                      (error-message-string err)))))

(defun kargu--stream-line (process line on-delta &optional on-event)
  "Handle one complete SSE LINE from PROCESS.
Non-\"data:\" lines (HTTP headers, comments, keep-alives) are
ignored.  PROCESS is only used for logging context."
  (ignore process)
  (setq line (string-trim-right line "\r"))
  (when (string-prefix-p "data:" line)
    (let ((data (string-trim (substring line (length "data:")))))
      (when (and (not (string-empty-p data))
                 (not (equal data "[DONE]")))
        (kargu--log-block "SSE data" data t)
        (when-let* ((event (kargu--json-decode-safe data)))
          (when (functionp on-event)
            (funcall on-event event))
          (when (functionp on-delta)
            (condition-case-unless-debug err
                (funcall on-delta event)
              (error
               (kargu-log 'warn "on-delta callback failed: %s"
                                (error-message-string err))))))))))

(defun kargu--api-handle-body (body callback &optional url headers payload gen
                                   on-delta attempt parsed-events)
  "Process a successful HTTP BODY string and dispatch CALLBACK.
Accepts both ordinary JSON bodies and SSE stream bodies; SSE
bodies are reduced to an ordinary response alist first.
When PARSED-EVENTS is non-nil, use them directly without re-parsing
the entire BODY string.
Non-JSON, non-SSE bodies (HTML error pages, plain-text HTTP
failures) are surfaced as errors instead of being treated as an
empty successful completion.
When URL is supplied, HTTP 200 bodies that carry a retryable
provider error (SSE `error' events, 502/overloaded) resend the
same payload instead of finishing as an empty assistant turn.
`kargu--busy' stays set across those retries."
  (let ((trimmed (and (stringp body) (string-trim body)))
        (attempt (or attempt 0)))
    (kargu--log-block "IN HTTP body" (or body "")
                      (kargu--log-looks-json-p trimmed))
    (let* ((response
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
                  `(("error" .
                     (("message" . "SSE body contained no data events")))))))
             (t
              `(("error" .
                 (("message" . ,(truncate-string-to-width trimmed 300))))))))
           (err (and response (kargu-response-error-message response))))
      (when (and kargu-log-wire response)
        (kargu--log-block "IN reconstructed JSON"
                          (kargu--json-encode response)
                          t))
      (cond
       ((and err
             (kargu--api-error-looks-retryable-p err)
             (kargu--api-schedule-retry
              url headers payload gen callback on-delta attempt
              (format "HTTP 200: %s" err)))
        nil)
       ((null response)
        (setq kargu--busy nil)
        (funcall callback
                 (kargu--api-error-alist
                  (format "HTTP 200: empty or invalid response body: %s"
                          (truncate-string-to-width
                           (or body "") 200)))))
       (err
        (setq kargu--busy nil)
        (funcall callback
                 (kargu--api-error-alist (format "HTTP 200: %s" err))))
       ((null (kargu--aget response "choices"))
        (let ((parsed (kargu--provider-error-text response)))
          (if (and parsed
                   (kargu--api-error-looks-retryable-p parsed)
                   (kargu--api-schedule-retry
                    url headers payload gen callback on-delta attempt
                    (format "HTTP 200: %s" parsed)))
              nil
            (setq kargu--busy nil)
            (funcall callback
                     (kargu--api-error-alist
                      (if parsed
                          (format "HTTP 200: %s" parsed)
                        (format "HTTP 200: response contained no choices%s"
                                (if (and trimmed (not (string-empty-p trimmed)))
                                    (concat ": " (truncate-string-to-width
                                                  trimmed 200))
                                  ""))))))))
       (t
        (setq kargu--busy nil)
        (kargu-circuit-record-success)
        (kargu--record-usage response)
        (kargu--history-append-assistant response)
        (funcall callback response))))))

(defun kargu--record-usage (response)
  "Accumulate the token usage of RESPONSE in `kargu--session'."
  (when-let* ((usage (kargu--aget response "usage")))
    (let ((in (kargu--aget usage "prompt_tokens"))
          (out (kargu--aget usage "completion_tokens")))
      (plist-put kargu--session :requests
                 (1+ (or (plist-get kargu--session :requests) 0)))
      (when (numberp in)
        (plist-put kargu--session :last-prompt-tokens in)
        (plist-put kargu--session :tokens-in
                   (+ (or (plist-get kargu--session :tokens-in) 0) in)))
      (when (numberp out)
        (plist-put kargu--session :tokens-out
                   (+ (or (plist-get kargu--session :tokens-out) 0) out)))
      (when (fboundp 'kargu-chat-refresh-footer)
        (ignore-errors (kargu-chat-refresh-footer)))
      (force-mode-line-update t)
      (kargu-log 'info "usage: %s in / %s out (session: %s)"
                       in out (kargu-session-usage))))
  kargu--session)

(provide 'kargu/api/http)

;;; kargu/api/http.el ends here
