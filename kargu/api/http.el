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
(require 'kargu/providers/params)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu-provider-format-headers "kargu/providers/registry" (format))

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

(declare-function kargu-loop-running-p "kargu/loop" ())

(defun kargu-busy-p ()
  "Return non-nil while a chat request is in flight."
  kargu--busy)

(defun kargu-api-clear-busy ()
  "Clear the in-flight busy flag and update status when no loop is active."
  (setq kargu--busy nil)
  (unless (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (when (fboundp 'kargu-state-transition-status)
      (kargu-state-transition-status :idle))))

(defun kargu-api-cancel ()
  "Cancel the current request or in-flight agent call.
Stale response callbacks are turned into no-ops via the
generation counter; the active curl process is terminated and
the UI and central state are left in a consistent state."
  (interactive)
  (cl-incf kargu--generation)
  (when (and (processp kargu--current-process)
             (process-live-p kargu--current-process))
    (ignore-errors (delete-process kargu--current-process)))
  (setq kargu--current-process nil)
  (setq kargu--busy nil)
  (unless (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (when (fboundp 'kargu-state-transition-status)
      (kargu-state-transition-status :idle "user cancelled")))
  (kargu-log 'warn "request cancelled")
  (message "kargu: cancelled in-flight request"))

(declare-function kargu-provider-cache-marker-p "kargu/providers/registry" (id))
(declare-function kargu-provider-reasoning-shape "kargu/providers/registry" (id))

(defun kargu--apply-prompt-caching-messages (raw-msgs tools-len)
  "Attach cache_control markers to RAW-MSGS when appropriate.
TOOLS-LEN is the number of tools available."
  ;; 1. When tools is empty (e.g. ask mode), attach cache_control to system prompt
  (when (and (= tools-len 0) (> (length raw-msgs) 0))
    (let ((sys-msg (car raw-msgs)))
      (when (equal (kargu--aget sys-msg "role") "system")
        (unless (assoc "cache_control" sys-msg)
          (setcar raw-msgs
                  (append sys-msg '(("cache_control" . (("type" . "ephemeral"))))))))))
  ;; 2. Attach cache_control to the last completed turn before current prompt
  ;; (turn length - 2) so past conversation history is 100% cached on multi-turn
  ;; sessions and restored history chats.
  (when (>= (length raw-msgs) 2)
    (let* ((target-idx (- (length raw-msgs) 2))
           (target-msg (nth target-idx raw-msgs)))
      (unless (assoc "cache_control" target-msg)
        (setcar (nthcdr target-idx raw-msgs)
                (append target-msg '(("cache_control" . (("type" . "ephemeral")))))))))
  raw-msgs)

(defun kargu--apply-prompt-caching-tools (tools)
  "Attach cache_control marker to the last tool definition in TOOLS vector."
  (let* ((tools-list (append tools nil))
         (last-idx (1- (length tools-list)))
         (last-tool (nth last-idx tools-list)))
    (unless (assoc "cache_control" last-tool)
      (setcar (nthcdr last-idx tools-list)
              (append last-tool '(("cache_control" . (("type" . "ephemeral"))))))
      (setq tools (vconcat tools-list))))
  tools)

(defun kargu-reasoning-effort-level ()
  "The reasoning effort to send as a string, or nil to send none.
The one place that reads `kargu-reasoning-effort': nil, \"off\" and the
empty string mean the user chose no effort.  \"none\" is a real level
that some models accept, so it is sent."
  (let ((effort (and kargu-reasoning-effort
                     (string-trim (format "%s" kargu-reasoning-effort)))))
    (and effort
         (not (member (downcase effort) '("" "nil" "off")))
         effort)))

(defun kargu-reasoning-budget ()
  "The thinking token budget when it is a positive integer, else nil."
  (and (integerp kargu-thinking-budget)
       (> kargu-thinking-budget 0)
       kargu-thinking-budget))

(defun kargu--build-reasoning-params (&optional provider)
  "Request entries for effort and thinking budget in PROVIDER's wire shape.
The shape comes from the provider's format record (`:reasoning-shape')."
  (let ((effort (kargu-reasoning-effort-level))
        (budget (kargu-reasoning-budget))
        (shape (if (fboundp 'kargu-provider-reasoning-shape)
                   (kargu-provider-reasoning-shape
                    (or provider (kargu--provider-name)))
                 'effort)))
    (pcase shape
      ('thinking
       (and budget
            `(("thinking" . (("type" . "enabled")
                             ("budget_tokens" . ,budget))))))
      ('nested
       (let ((nested (append (and effort `(("effort" . ,effort)))
                             (and budget `(("max_tokens" . ,budget))))))
         (and nested `(("reasoning" . ,nested)))))
      (_ (and effort `(("reasoning_effort" . ,effort)))))))

(defun kargu--payload-merge (payload extra)
  "PAYLOAD with the entries of EXTRA added; an EXTRA key replaces its twin."
  (append (seq-remove (lambda (cell) (assoc (car cell) extra)) payload)
          extra))

(defun kargu--payload-sampling-entries ()
  "Request entries for temperature and the output token cap."
  (append (and kargu-temperature `(("temperature" . ,kargu-temperature)))
          (and kargu-max-tokens `(("max_tokens" . ,kargu-max-tokens)
                                  ("max_completion_tokens" . ,kargu-max-tokens)))))

(defun kargu--payload-tools-entries (tools cache-marked)
  "Request entries for the TOOLS vector; none when it is empty.
CACHE-MARKED puts a cache marker on the last tool."
  (when (> (length tools) 0)
    `(("tools" . ,(if cache-marked (kargu--apply-prompt-caching-tools tools) tools))
      ("tool_choice" . "auto"))))

(defun kargu--build-payload (&rest extra)
  "Assemble the chat-completions request payload.
EXTRA is a list of additional (KEY . VALUE) conses that replace or add
entries (e.g. (\"stream\" . t)).  The \"tools\" array is only included when
at least one tool is VISIBLE after `kargu--tools-visible-p' filtering."
  (let* ((tools (kargu--build-tools-vector))
         (cache-marked (kargu-provider-cache-marker-p
                        (downcase (string-trim (format "%s" (kargu--provider-name))))))
         (messages (copy-tree kargu--message-history t))
         (payload
          (append
           `(("model" . ,(kargu--model))
             ("messages" . ,(vconcat (if cache-marked
                                         (kargu--apply-prompt-caching-messages
                                          messages (length tools))
                                       messages))))
           (kargu--payload-sampling-entries)
           (kargu--payload-tools-entries tools cache-marked))))
    (dolist (entries (list (kargu--build-reasoning-params)
                           (and (fboundp 'kargu-provider-params-build-payload)
                                (kargu-provider-params-build-payload))
                           extra))
      (setq payload (kargu--payload-merge payload entries)))
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
  (let ((raw (and err (kargu--plz-header err "retry-after"))))
    (when (and (stringp raw) (string-match "\\`[0-9]+\\'" (string-trim raw)))
      (min kargu-api-retry-after-max (string-to-number raw)))))

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
                      (kargu--json-encode payload)
                      t)))

(defun kargu--api-error-looks-retryable-p (message)
  "Non-nil when MESSAGE looks like HTTP 429/5xx or provider overload.
HTTP 200 bodies can still carry an SSE `error' event with a 502
or \"overloaded\" text; those are retryable the same way as a
transport-level 502."
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
        (when (or (kargu--api-retryable-p err)
                  (null (kargu--plz-http-status err)))
          (kargu-circuit-record-failure msg))
        (kargu-log 'error "request failed: %s" msg)
        (funcall callback (kargu--api-error-alist msg))))))

(defun kargu--api-provider-format (provider-name)
  "API format symbol for PROVIDER-NAME, or nil."
  (when (and provider-name (fboundp 'kargu-provider-format))
    (kargu-provider-format provider-name)))

(defun kargu--api-auth-headers (key format)
  "Authorization headers for KEY in FORMAT.
The format record's `:auth' selects `x-api-key' or a bearer token.
An empty KEY sends neither."
  (when (kargu--nonempty key)
    (if (eq (kargu-provider-format-auth format) 'x-api-key)
        `(("x-api-key" . ,key))
      `(("Authorization" . ,(concat "Bearer " key))))))

(defun kargu--api-session-id ()
  "Session id sent in headers that ask for it."
  (if (fboundp 'kargu-session-id) (kargu-session-id) "default"))

(defun kargu--api-default-headers (format expanded)
  "Format-record headers for FORMAT that EXPANDED does not already set."
  (let (out)
    (dolist (pair (kargu-provider-format-headers format))
      (unless (assoc (car pair) expanded)
        (push (kargu--api-expand-header pair (kargu--api-session-id)) out)))
    (nreverse out)))

(defun kargu--api-expand-header (pair session-id)
  "Return header PAIR with a symbolic value filled in.
`:session' becomes SESSION-ID and `:app-url' becomes `kargu-app-url'."
  (pcase (cdr-safe pair)
    (:session (cons (car pair) session-id))
    (:app-url (cons (car pair) kargu-app-url))
    (_ pair)))

(defun kargu--api-headers (key &optional provider-name)
  "HTTP headers for the active or specified PROVIDER-NAME.
KEY is the resolved secret.  An empty KEY omits Authorization so
local or keyless proxies still work.  Auth and extra headers come
from the provider catalog `:format' and `:extra-headers'."
  (let* ((sid (kargu--api-session-id))
         (pname (if provider-name
                    (format "%s" provider-name)
                  (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
         (pname-lower (downcase (string-trim pname)))
         (format (kargu--api-provider-format pname-lower))
         (extra (and (fboundp 'kargu-provider-extra-headers)
                     (kargu-provider-extra-headers pname-lower)))
         (expanded (and (listp extra)
                        (mapcar (lambda (pair)
                                  (kargu--api-expand-header pair sid))
                                extra))))
    (append
     '(("Content-Type" . "application/json"))
     (kargu--api-auth-headers key format)
     (kargu--api-default-headers format expanded)
     expanded)))

(defun kargu--api-post (url headers payload gen callback &optional on-delta attempt)
  "POST PAYLOAD to URL via plz, dispatching to CALLBACK.
GEN is the request generation for cancellation.  When ON-DELTA
is supplied and `kargu-stream' is non-nil, use the SSE
streaming transport; otherwise a single asynchronous request.
ATTEMPT is the 0-based retry count.  Neither transport ever
blocks the UI thread."
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
         ;; A reply that arrives after the run was cancelled reaches no one.
         (live-delta (and on-delta
                          (lambda (event)
                            (when (= gen kargu--generation)
                              (funcall on-delta event)))))
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
                             (kargu--stream-filter process string live-delta on-event))
                   :then (lambda (body)
                           (kargu--stream-flush kargu--current-process live-delta on-event)
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

(defun kargu--stream-flush (process on-delta on-event)
  "Handle the last SSE line of PROCESS when the stream ended without a newline."
  (when (processp process)
    (let ((rest (process-get process :kargu-raw)))
      (process-put process :kargu-raw nil)
      (when (and (stringp rest) (not (string-empty-p (string-trim rest))))
        (condition-case-unless-debug err
            (kargu--stream-line process (decode-coding-string rest 'utf-8)
                                on-delta on-event)
          (error (kargu-log 'error "stream flush error: %s"
                            (error-message-string err))))))))

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

(defun kargu--api-decode-body-response (body trimmed parsed-events)
  "Decode raw HTTP BODY or PARSED-EVENTS into a response alist."
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
  (kargu--record-usage response)
  (kargu--history-append-assistant response)
  (funcall callback response))

(defun kargu--api-dispatch-error (callback msg)
  "Mark kargu as not busy and invoke CALLBACK with an error alist for MSG.
An upstream-unavailable MSG counts against the circuit breaker here, so
the loop never has to record it again."
  (setq kargu--busy nil)
  (when (kargu--api-error-looks-retryable-p msg)
    (kargu-circuit-record-failure msg))
  (funcall callback (kargu--api-error-alist msg)))

(defun kargu--api-handle-no-choices (response trimmed url headers payload gen
                                             callback on-delta attempt)
  "Handle a response with no choices, retrying if parsed error is retryable."
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
  "Process a successful HTTP BODY string and dispatch CALLBACK.
Accepts both ordinary JSON bodies and SSE stream bodies; SSE
bodies are reduced to an ordinary response alist first."
  (let* ((trimmed (and (stringp body) (string-trim body)))
         (attempt (or attempt 0)))
    (kargu--log-block "IN HTTP body" (or body "")
                      (kargu--log-looks-json-p trimmed))
    (let* ((response (kargu-api-normalize-response
                      (kargu--api-decode-body-response body trimmed parsed-events)))
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
        (kargu--api-dispatch-error
         callback
         (format "HTTP 200: empty or invalid response body: %s"
                 (truncate-string-to-width (or body "") 200))))
       (err
        (kargu--api-dispatch-error
         callback
         (format "HTTP 200: %s" err)))
       ((null (kargu--aget response "choices"))
        (kargu--api-handle-no-choices
         response trimmed url headers payload gen callback on-delta attempt))
       (t
        (kargu--api-handle-success response callback))))))

(defun kargu--record-usage (response)
  "Accumulate the token usage of RESPONSE in `kargu--session'."
  (when-let* ((usage (kargu--aget response "usage")))
    (let ((in (kargu--aget usage "prompt_tokens"))
          (out (kargu--aget usage "completion_tokens")))
      (kargu-session-record-usage in out)
      (when (fboundp 'kargu-state-record-tokens)
        (kargu-state-record-tokens (and (numberp in) in)
                                   (and (numberp out) out)))
      (when (fboundp 'kargu-chat-refresh-footer)
        (ignore-errors (kargu-chat-refresh-footer)))
      (force-mode-line-update t)
      (kargu-log 'info "usage: %s in / %s out (session: %s)"
                       in out (kargu-session-usage))))
  kargu--session)

(provide 'kargu/api/http)

;;; kargu/api/http.el ends here
