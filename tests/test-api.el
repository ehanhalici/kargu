;;; tests/test-api.el --- Tests for kargu/api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)

(defvar kargu-api-timeout)
(defvar kargu-api-stall-timeout)
(defvar kargu-api-stream-ceiling)

(ert-deftest kargu-api-retry-after-supports-dates-and-bounds-test ()
  "Retry-After accepts HTTP dates, clamps delays and preserves match data."
  (let* ((now (date-to-time "Sun, 18 Oct 2026 12:00:00 GMT"))
         (kargu-api-retry-after-max 120))
    (dolist (case '((" 10 " . 10) ("999" . 120)
                    ("Sun, 18 Oct 2026 12:01:00 GMT" . 60)
                    ("Sun, 18 Oct 2026 13:00:00 GMT" . 120)
                    ("Sun, 18 Oct 2026 11:00:00 GMT" . 0)
                    ("invalid" . nil)))
      (cl-letf (((symbol-function 'kargu--plz-header) (lambda (&rest _) (car case)))
                ((symbol-function 'current-time) (lambda () now)))
        (string-match "keep" "keep")
        (let ((match (match-data)))
          (if (cdr case)
              (should (= (kargu--api-retry-after-seconds 'error) (cdr case)))
            (should-not (kargu--api-retry-after-seconds 'error)))
          (should (equal (match-data) match)))))))

(ert-deftest kargu-api-retry-observers-cannot-post-after-cancellation-test ()
  "Retry observers run once, and cancellation during notification prevents POST."
  (let* ((kargu--generation 100) (posts 0) (observations 0)
         (kargu-api-retry-hook
          (list (lambda (&rest _) (error "bad observer"))
                (lambda (&rest _) (cl-incf observations) (setq kargu--generation 200)))))
    (cl-letf (((symbol-function 'kargu--api-post) (lambda (&rest _) (cl-incf posts))))
      (kargu-api--retry-post 100 :url "https://example.invalid" :attempt 1)
      (should (= observations 1))
      (should (zerop posts))
      (kargu-api--retry-post 100)
      (should (= observations 1)))))

(ert-deftest kargu-api-scheduled-retry-publishes-boundary-only-when-starting-test ()
  "A scheduled retry announces its original event consumer only when it starts."
  (let* ((kargu--generation 100) (kargu-api-retry-max 2) scheduled seen
         (consumer #'ignore)
         (kargu-api-retry-hook (list (lambda (generation delta)
                                       (push (cons generation delta) seen)))))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest _) (setq scheduled function)))
              ((symbol-function 'kargu--api-post) #'ignore))
      (should (kargu--api-schedule-retry "https://example.invalid" nil nil 100
                                        #'ignore consumer 0 "overloaded"))
      (should-not seen)
      (funcall scheduled)
      (should (equal seen (list (cons 100 consumer)))))))

(ert-deftest kargu-api-overflow-does-not-confuse-token-rate-limits-test ()
  "Only explicit context or input-length errors request compaction."
  (dolist (text '("context_length_exceeded" "Maximum context length is 4096"
                  "Prompt is too long" "Input exceeds the context window"
                  "Context window token limit exceeded"))
    (should (kargu--overflow-message-p text)))
  (dolist (text '("Too many tokens per minute" "Token limit reached: TPM 10000"
                  "Maximum tokens per minute exceeded" "max_tokens exceeds limit"
                  "Rate limit exceeded. Try again later."))
    (should-not (kargu--overflow-message-p text))))

(ert-deftest kargu-api-continuation-errors-never-redeliver-or-clear-new-work-test ()
  "Sync and async callback failures do not redeliver or release a newer turn."
  (dolist (synchronous '(nil t))
    (let ((kargu--generation 100) (kargu--current-process nil) (kargu--busy nil)
          (kargu-session--context
           (kargu-test-session-with-history
            :messages nil)) (delivered 0) (stored 0) held)
      (cl-letf (((symbol-function 'kargu--api-validate-preflight) #'ignore)
                ((symbol-function 'kargu-api-build-payload) (lambda (&rest _) nil))
                ((symbol-function 'kargu--api-headers) (lambda (&rest _) nil))
                ((symbol-function 'kargu-api-store-assistant-turn)
                 (lambda (_ &optional _) (cl-incf stored)))
                ((symbol-function 'kargu--api-post)
                 (lambda (_url _headers _payload _gen callback &rest _)
                   (setq held callback)
                   (when synchronous (funcall callback nil)))))
        (kargu-api--send-turn
         :prompt "keep this turn" :key "" :base "https://example.invalid"
         :callback (lambda (_)
                     (cl-incf delivered)
                     (setq kargu--generation 200
                           kargu--current-process 'new-process kargu--busy t)
                     (error "Continuation failed")))
        (unless synchronous (funcall held nil))
        (funcall held nil)
        (should (= delivered 1))
        (should (= stored 1))
        (should (eq kargu--current-process 'new-process))
        (should kargu--busy)
        (should (equal (kargu-aget (car (kargu-history-messages)) "content")
                       "keep this turn"))))))

(ert-deftest kargu-api-reply-storage-failure-is-delivered-once-test ()
  "Storage failures reach the caller once in both sync and async transports."
  (dolist (synchronous '(nil t))
    (let ((kargu--generation 100) (kargu--current-process nil) (kargu--busy nil)
          (kargu-session--context
           (kargu-test-session-with-history
            :messages nil)) results held)
      (cl-letf (((symbol-function 'kargu--api-validate-preflight) #'ignore)
                ((symbol-function 'kargu-api-build-payload) (lambda (&rest _) nil))
                ((symbol-function 'kargu--api-headers) (lambda (&rest _) nil))
                ((symbol-function 'kargu-api-store-assistant-turn)
                 (lambda (_ &optional _) (error "Storage failed")))
                ((symbol-function 'kargu--api-post)
                 (lambda (_url _headers _payload _gen callback &rest _)
                   (setq held callback)
                   (when synchronous (funcall callback nil)))))
        (kargu-api--send-turn :prompt "hello" :key "" :base "https://example.invalid"
                              :callback (lambda (response) (push response results)))
        (unless synchronous (funcall held nil))
        (funcall held nil)
        (should (= (length results) 1))
        (should (string-search "Storage failed"
                               (kargu-response-error-message (car results))))
        (should-not kargu--busy)))))

(ert-deftest kargu-api-watch-startup-failure-never-launches-a-second-request-test ()
  "Watch failure closes the stream before delivering a single error result."
  (with-temp-buffer
    (let* ((old (make-pipe-process :name "kargu-startup-old" :buffer (current-buffer)))
           (new (make-pipe-process :name "kargu-startup-new" :buffer (current-buffer)))
           (kargu--generation 50) (kargu--current-process nil)
           (kargu--busy t) (kargu-stream t)
           (requests 0) options results)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-circuit-allow-request-p) (lambda (&optional _scope) t))
                    ((symbol-function 'plz)
                     (lambda (_method _url &rest args)
                       (cl-incf requests) (setq options args) old))
                    ((symbol-function 'kargu--api-arm-stream-watch)
                     (lambda (process)
                       (process-put process :kargu-stream-timer
                                    (run-at-time 60 nil #'ignore))
                       (error "watch setup failed"))))
            (kargu--api-post
             "https://example.invalid" nil nil 50
             (lambda (response)
               (push response results)
               (setq kargu--current-process new kargu--busy t))
             #'ignore)
            (should (= requests 1))
            (should (= (length results) 1))
            (should (string-search "watch setup failed"
                                   (kargu-response-error-message (car results))))
            (should-not (process-live-p old))
            (should-not (process-get old :kargu-stream-timer))
            (funcall (plist-get options :then) "{}")
            (funcall (plist-get options :else) nil)
            (should (= (length results) 1))
            (should (eq kargu--current-process new))
            (should (process-live-p new))
            (should kargu--busy))
        (kargu--api-cancel-stream-watch old)
        (delete-process old)
        (delete-process new)))))

(ert-deftest kargu-api-synchronous-completion-keeps-new-process-test ()
  "A synchronous completion cannot publish an obsolete process afterwards."
  (dolist (stream '(nil t))
    (let ((kargu--generation 60) (kargu--current-process nil) armed)
      (cl-letf (((symbol-function 'plz)
                 (lambda (_method _url &rest options)
                   (funcall (plist-get options :then) "{}")
                   'old-process))
                ((symbol-function 'kargu--api-handle-body)
                 (lambda (_body callback &rest _) (funcall callback 'ok)))
                ((symbol-function 'kargu--api-arm-stream-watch)
                 (lambda (_) (setq armed t))))
        (let ((finish (lambda (_)
                        (setq kargu--generation 61
                              kargu--current-process 'new-process))))
          (if stream
              (kargu--api-post-streaming "https://example.invalid" nil nil 60 finish #'ignore)
            (kargu--api-post-plain "https://example.invalid" nil nil 60 finish)))
        (should (eq kargu--current-process 'new-process))
        (should-not armed)))))

(ert-deftest kargu-api-stream-start-errors-do-not-trigger-plain-fallback-test ()
  "A startup or synchronous continuation error never resends the request."
  (dolist (completed '(nil t))
    (let ((kargu--generation 70) (kargu--current-process nil)
          (kargu-stream t) (requests 0) (delivered 0))
      (cl-letf (((symbol-function 'kargu-circuit-allow-request-p) (lambda (&optional _scope) t))
                ((symbol-function 'plz)
                 (lambda (_method _url &rest options)
                   (cl-incf requests)
                   (when completed (funcall (plist-get options :then) "{}"))
                   (error "transport startup failed")))
                ((symbol-function 'kargu--api-handle-body)
                 (lambda (_body callback &rest _) (funcall callback 'ok))))
        (should-error
         (kargu--api-post "https://example.invalid" nil nil 70
                          (lambda (_) (cl-incf delivered) (error "continuation failed"))
                          #'ignore))
        (should (= requests 1))
        (should (= delivered (if completed 1 0)))))))

(ert-deftest kargu-api-stale-callback-keeps-new-process-test ()
  "Old plain and streaming completions cannot clear a new request."
  (dolist (stream '(nil t))
    (let ((kargu--generation 10)
          (kargu--current-process nil)
          then else delivered)
      (cl-letf (((symbol-function 'plz)
                 (lambda (_method _url &rest options)
                   (setq then (plist-get options :then)
                         else (plist-get options :else))
                   'old-process)))
        (if stream
            (kargu--api-post-streaming "https://example.invalid" nil nil 10
                                       (lambda (_) (setq delivered t)) #'ignore)
          (kargu--api-post-plain "https://example.invalid" nil nil 10
                                 (lambda (_) (setq delivered t))))
        (setq kargu--generation 11 kargu--current-process 'new-process)
        (funcall then "{}")
        (should (eq kargu--current-process 'new-process))
        (funcall else nil)
        (should (eq kargu--current-process 'new-process))
        (should-not delivered)))))

(ert-deftest kargu-api-completion-is-delivered-once-test ()
  "A repeated transport completion delivers its result only once."
  (dolist (stream '(nil t))
    (let ((kargu--generation 20)
          (kargu--current-process nil)
          then else (delivered 0))
      (cl-letf (((symbol-function 'plz)
                 (lambda (_method _url &rest options)
                   (setq then (plist-get options :then)
                         else (plist-get options :else))
                   nil))
                ((symbol-function 'kargu--api-handle-body)
                 (lambda (_body callback &rest _) (funcall callback 'ok))))
        (if stream
            (kargu--api-post-streaming "https://example.invalid" nil nil 20
                                       (lambda (_) (cl-incf delivered)) #'ignore)
          (kargu--api-post-plain "https://example.invalid" nil nil 20
                                 (lambda (_) (cl-incf delivered))))
        (funcall then "{}")
        (funcall then "{}")
        (funcall else nil)
        (should (= delivered 1))))))

(ert-deftest kargu-api-stream-flush-forwards-final-event-test ()
  "A final SSE line without a newline reaches both consumers."
  (with-temp-buffer
    (let* ((kargu--generation 30)
           (kargu--current-process nil)
           (process (make-pipe-process :name "kargu-flush" :buffer (current-buffer)))
           events parsed
           (request (kargu-http--make-request
                     :generation 30 :process process :attempt 0
                     :on-delta (lambda (event) (push event events)))))
      (unwind-protect
          (progn
            (process-put process :kargu-raw "data: {\"choices\":[]}")
            (cl-letf (((symbol-function 'kargu--api-handle-body)
                       (lambda (&rest args) (setq parsed (nth 8 args)))))
              (kargu-http--finish-stream request ""))
            (should (= (length events) 1))
            (should (equal events parsed)))
        (delete-process process)))))

(ert-deftest kargu-api-sse-preserves-split-utf8-and-match-data-test ()
  "Split UTF-8 bytes reconstruct one event without leaking callback matches."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let* ((process (make-pipe-process :name "kargu-utf8" :buffer (current-buffer)))
           (raw (encode-coding-string "data: {\"content\":\"ğ🙂\"}\n\n" 'utf-8))
           (split (1+ (string-search (encode-coding-string "ğ" 'utf-8) raw)))
           events
           (callback (lambda (event)
                       (string-match "changed" "changed")
                       (push event events))))
      (unwind-protect
          (progn
            (string-match "saved" "saved")
            (let ((saved (match-data)))
              (kargu--stream-filter process (substring raw 0 split) callback)
              (should-not events)
              (kargu--stream-filter process (substring raw split) callback)
              (should (equal (match-data) saved)))
            (should (= (length events) 1))
            (should (equal (kargu-aget (car events) "content") "ğ🙂"))
            (should (equal (buffer-string) raw)))
        (delete-process process)))))

(declare-function kargu-api-chat-url "kargu/api/wire" (base format))
(declare-function kargu-api-prepare-payload "kargu/api/wire" (payload format))
(declare-function kargu-api-normalize-response "kargu/api/wire" (response))
(declare-function kargu-provider-format-stream-p "kargu/providers/registry" (format))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu--api-headers "kargu/api/http" (key &optional provider-name))
(declare-function kargu--api-error-looks-retryable-p "kargu/api/http" (message))
(declare-function kargu--stream-filter "kargu/api/http" (process string on-delta &optional on-event))
(declare-function kargu--api-arm-stream-watch "kargu/api/http" (process))
(declare-function kargu--api-stream-watch-tick "kargu/api/http" (process))
(declare-function kargu--api-cancel-stream-watch "kargu/api/http" (process))

(ert-deftest kargu-api-response-vector-choices-test ()
  "Ensure kargu--response-choice handles vector choices correctly (Bug 2 regression)."
  (let ((resp-vec '(("choices" . [(("index" . 0)
                                   ("message" . (("role" . "assistant")
                                                 ("content" . "vector response test")))
                                   ("finish_reason" . "stop"))])))
        (resp-list '(("choices" . ((("index" . 0)
                                    ("message" . (("role" . "assistant")
                                                  ("content" . "list response test")))
                                    ("finish_reason" . "stop")))))))
    (should (equal (kargu-response-text resp-vec) "vector response test"))
    (should (equal (kargu-response-text resp-list) "list response test"))
    (should (equal (kargu-response-finish-reason resp-vec) "stop"))
    (should (equal (kargu-response-finish-reason resp-list) "stop"))))

(ert-deftest kargu-api-stream-vector-choices-test ()
  "Ensure SSE delta accumulator handles vector choices and vector frags (Bug 3 regression)."
  (let* ((event1 '(("choices" . [(("index" . 0)
                                  ("delta" . (("content" . "hello ")))
                                  ("finish_reason" . nil))])))
         (event2 '(("choices" . [(("index" . 0)
                                  ("delta" . (("content" . "world!")))
                                  ("finish_reason" . "stop"))])))
         (reconstructed (kargu--accumulate-stream-deltas (list event1 event2))))
    (should (equal (kargu-response-text reconstructed) "hello world!"))
    (should (equal (kargu-response-finish-reason reconstructed) "stop"))))

(ert-deftest kargu-api-circuit-breaker-lifecycle-test ()
  "Test circuit breaker state machine transitions."
  (kargu-circuit-reset)
  (should (eq kargu-circuit--state :closed))
  (should (kargu-circuit-allow-request-p))
  ;; Trigger failures up to threshold
  (dotimes (_ 4)
    (kargu-circuit-record-failure "500 upstream"))
  ;; State must be :open
  (should (eq kargu-circuit--state :open))
  (should-not (kargu-circuit-allow-request-p))
  ;; Reset back to :closed
  (kargu-circuit-record-success)
  (should (eq kargu-circuit--state :closed))
  (should (kargu-circuit-allow-request-p)))

(ert-deftest kargu-circuit-cancel-and-rejection-release-canary-test ()
  "Cancellation and terminal rejections free the canary without resetting failures."
  (dolist (outcome '(cancel http-error body-error startup-error))
    (let ((kargu-circuit--state :half-open)
          (kargu-circuit--probe-inflight nil)
          (kargu-circuit--failure-count 4)
          (kargu--current-process nil)
          (kargu--generation 50)
          (kargu--busy t) responses)
      (should (kargu-circuit-allow-request-p))
      (should-not (kargu-circuit-allow-request-p))
      (pcase outcome
        ('cancel (kargu-api-cancel))
        ('startup-error (kargu-api-clear-busy))
        ('body-error (kargu--api-dispatch-error (lambda (value) (push value responses)) "Invalid request"))
        ('http-error
         (cl-letf (((symbol-function 'kargu--plz-http-status) (lambda (_) 401))
                   ((symbol-function 'kargu--plz-error-message) (lambda (_) "Unauthorized")))
           (kargu--api-on-transport-error nil nil nil 50
                                          (lambda (value) (push value responses)) nil 0 'mock-error))))
      (should-not kargu-circuit--probe-inflight)
      (should (eq kargu-circuit--state :half-open))
      (should (= kargu-circuit--failure-count 4))
      (should (kargu-circuit-allow-request-p)))))

(ert-deftest kargu-circuit-retry-keeps-exclusive-canary-test ()
  "A scheduled transport retry retains its canary until actual completion."
  (let ((kargu-circuit--state :half-open)
        (kargu-circuit--probe-inflight t)
        (kargu--generation 70) (kargu-api-retry-max 1) scheduled)
    (cl-letf (((symbol-function 'kargu--plz-http-status) (lambda (_) 503))
              ((symbol-function 'run-at-time) (lambda (&rest _) (setq scheduled t))))
      (kargu--api-on-transport-error nil nil nil 70 #'ignore nil 0 'mock-error)
      (should scheduled)
      (should-not (kargu-circuit-allow-request-p)))))

(ert-deftest kargu-api-stream-accumulator-chunks-test ()
  "Test linear stream accumulator with multiple text chunks and reasoning."
  (let* ((ev1 '(("choices" . [(("index" . 0)
                               ("delta" . (("content" . "part1 ")
                                           ("reasoning_content" . "think1 ")))
                               ("finish_reason" . nil))])))
         (ev2 '(("choices" . [(("index" . 0)
                               ("delta" . (("content" . "part2")
                                           ("reasoning_content" . "think2")))
                               ("finish_reason" . "stop"))])))
         (resp (kargu--accumulate-stream-deltas (list ev1 ev2))))
    (should (equal (kargu-response-text resp) "part1 part2"))
    (should (equal (kargu-response-reasoning-text resp) "think1 think2"))
    (should (equal (kargu-response-finish-reason resp) "stop"))))

(ert-deftest kargu-api-timeout-config-test ()
  "Ensure kargu-api-timeout has a valid default."
  (require 'kargu/core)
  (should (numberp kargu-api-timeout))
  (should (> kargu-api-timeout 0))
  (should (numberp kargu-api-stall-timeout))
  (should (> kargu-api-stall-timeout 0))
  (should (numberp kargu-api-stream-ceiling))
  (should (> kargu-api-stream-ceiling kargu-api-timeout)))

(ert-deftest kargu-api-stream-stall-watch-test ()
  "A dead stream process drops its watch without recording an abort."
  (require 'kargu/api/http)
  (let* ((buf (generate-new-buffer " *kargu-stall*"))
         (proc (start-process "kargu-stall" buf "sleep" "30")))
    (unwind-protect
        (progn
          (process-put proc :kargu-last-byte 0)
          (kargu--stream-filter proc "data: {}\n" nil)
          (should (> (or (process-get proc :kargu-last-byte) 0) 0))
          (kargu--api-arm-stream-watch proc)
          (should (process-get proc :kargu-stream-timer))
          (delete-process proc)
          (kargu--api-stream-watch-tick proc)
          (should-not (process-get proc :kargu-stream-abort))
          (should-not (process-get proc :kargu-stream-timer)))
      (kargu--api-cancel-stream-watch proc)
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-api-anthropic-url-and-response-test ()
  "Anthropic format posts to /messages and comes back as choices."
  (require 'kargu/api/wire)
  (should (equal (kargu-api-chat-url "https://api.anthropic.com/v1" 'anthropic)
                 "https://api.anthropic.com/v1/messages"))
  (should (equal (kargu-api-chat-url "https://api.openai.com/v1" 'openapi)
                 "https://api.openai.com/v1/chat/completions"))
  (should-not (kargu-provider-format-stream-p 'anthropic))
  (should (eq (kargu-provider-format-auth 'anthropic) 'x-api-key))
  (let* ((payload '(("model" . "claude")
                    ("messages" . ((("role" . "system") ("content" . "be brief"))
                                   (("role" . "user") ("content" . "hi"))))))
         (body (kargu-api-prepare-payload payload 'anthropic))
         (native '(("stop_reason" . "end_turn")
                   ("content" . ((("type" . "text") ("text" . "hello"))))
                   ("usage" . (("input_tokens" . 3) ("output_tokens" . 1)))))
         (norm (kargu-api-normalize-response native))
         (tool '(("stop_reason" . "tool_use")
                 ("content" . ((("type" . "tool_use")
                                ("id" . "c1")
                                ("name" . "read")
                                ("input" . (("path" . "a")))))))))
    (should (equal (kargu-aget (car (kargu-aget body "system")) "text") "be brief"))
    (should (equal (kargu-response-answer-text norm) "hello"))
    (should (equal (kargu-response-finish-reason norm) "stop"))
    (should (equal (kargu-response-finish-reason (kargu-api-normalize-response tool))
                   "tool_calls"))
    (let ((call (car (append (kargu-response-tool-calls
                              (kargu-api-normalize-response tool))
                             nil))))
      (should (equal (kargu-aget (kargu-aget call "function") "name") "read")))))

(ert-deftest kargu-tool-flag-json-false-test ()
  "JSON false is not a true tool flag."
  (require 'kargu/api/tools)
  (should-not (kargu--tool-flag '(("background" . :json-false)) "background"))
  (should (kargu--tool-flag '(("background" . t)) "background"))
  (should-not (kargu--tool-flag '(("staged" . "false")) "staged")))

(ert-deftest kargu-api-opencode-session-header-test ()
  "Test that x-opencode-session header is generated and passed for OpenCode."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "opencode"))
        (kargu--session-id nil))
    (let ((headers (kargu--api-headers "test-key")))
      (should (assoc "x-opencode-session" headers))
      (should (stringp (cdr (assoc "x-opencode-session" headers))))
      (should (> (length (cdr (assoc "x-opencode-session" headers))) 10)))))

(ert-deftest kargu-reasoning-request-shape-follows-the-catalog-test ()
  "Effort and budget are shaped by the declared provider format."
  (let ((kargu-reasoning-effort 'none) (kargu-thinking-budget nil))
    (should (equal (kargu--build-reasoning-params "openai")
                   '(("reasoning_effort" . "none"))))
    (should (equal (kargu--build-reasoning-params "openrouter")
                   '(("reasoning" . (("effort" . "none")))))))
  (let ((kargu-reasoning-effort "off") (kargu-thinking-budget 4096))
    (should-not (kargu--build-reasoning-params "openai"))
    (should (equal (kargu--build-reasoning-params "openrouter")
                   '(("reasoning" . (("max_tokens" . 4096))))))
    (should (equal (kargu--build-reasoning-params "anthropic")
                   '(("thinking" . (("type" . "enabled") ("budget_tokens" . 4096))))))))

(ert-deftest kargu-payload-merge-replaces-duplicate-keys-test ()
  "Explicit entries replace existing keys without duplicate payload fields."
  (should (equal (kargu--payload-merge '(("a" . 1) ("thinking" . 2)) '(("thinking" . 3)))
                 '(("a" . 1) ("thinking" . 3)))))

(ert-deftest kargu-payload-no-provider-custom-parameters-test ()
  "Legacy custom JSON settings cannot override the supported core settings."
  (let ((kargu-temperature 0.2) (kargu-max-tokens 1234)
        (kargu-reasoning-effort nil) (kargu-thinking-budget nil)
        (kargu-session--context
         (kargu-test-session-with-history
          :messages '((("role" . "system") ("content" . "System"))
                      (("role" . "user") ("content" . "Hi"))))))
    (let ((payload (kargu--build-payload)))
      (should (equal (kargu-aget payload "temperature") 0.2))
      (should (= (kargu-aget payload "max_tokens") 1234))
      (should-not (kargu-aget payload "provider"))
      (should-not (string-search "[params" (kargu-chat--footer-string))))))

(ert-deftest kargu-tune-unselected-model-description-test ()
  "The remaining tuning menu works before a model has been selected."
  (cl-letf (((symbol-function 'kargu--model) (lambda () nil)))
    (should (string-search "not selected" (kargu-tune--model-desc)))))

(ert-deftest kargu-api-null-error-is-not-a-provider-failure-test ()
  "Null and false error fields are not errors; actual messages remain errors."
  (dolist (value '(nil :json-null :json-false))
    (should-not (kargu-response-error-message (list (cons "error" value))))
    (should (kargu-aget (kargu-api-normalize-response
                         (list (cons "type" "message") (cons "stop_reason" "end_turn")
                               (cons "error" value))) "choices")))
  (should (equal (kargu-response-error-message '(("error" . (("message" . "Rejected")))))
                 "Rejected")))

(provide 'tests/test-api)
;;; test-api.el ends here

(ert-deftest kargu-circuit-half-open-lets-one-probe-through-test ()
  "After the cooldown a single probe passes; asking whether it is open changes nothing."
  (kargu-circuit-reset)
  (let ((kargu-circuit-cooldown-seconds 0.0))
    (dotimes (_ kargu-circuit-failure-threshold)
      (kargu-circuit-record-failure "500"))
    (should (eq kargu-circuit--state :open))
    (should-not (kargu-circuit-open-p))
    (should (eq kargu-circuit--state :open))
    (should (kargu-circuit-allow-request-p))
    (should (eq kargu-circuit--state :half-open))
    (should-not (kargu-circuit-allow-request-p))
    (should (kargu-circuit-open-p))
    (kargu-circuit-record-success)
    (should (kargu-circuit-allow-request-p)))
  (kargu-circuit-reset))

(ert-deftest kargu-retry-statuses-have-one-list-test ()
  (let ((kargu-http-retry-statuses '(418)))
    (should (kargu--api-error-looks-retryable-p "HTTP 418: teapot"))
    (should-not (kargu--api-error-looks-retryable-p "HTTP 502: bad gateway"))))

(ert-deftest kargu-stream-tool-calls-keep-name-and-get-an-id-test ()
  "An empty later name is preserved and the boundary assigns a canonical ID."
  (let* ((events (list '(("choices" . ((("delta" . (("tool_calls" . ((("index" . 0)
                                                                      ("function" . (("name" . "read_file") ("arguments" . "{\"a\":"))))))))))))
                       '(("choices" . ((("delta" . (("tool_calls" . ((("index" . 0) ("id" . "")
                                                                      ("function" . (("name" . "") ("arguments" . "1}"))))))))
                                        ("finish_reason" . "tool_calls")))))))
         (resp (kargu-api-normalize-response (kargu--accumulate-stream-deltas events)))
         (call (car (kargu-seq-to-list (kargu-response-tool-calls resp)))))
    (should (equal (kargu-aget (kargu-aget call "function") "name") "read_file"))
    (should (string-prefix-p "call_kargu_" (kargu-aget call "id")))
    (should (equal (kargu-aget (kargu-aget call "function") "arguments") "{\"a\":1}"))))

(ert-deftest kargu-logical-request-cancel-clears-scheduled-retry-timer-test ()
  "Cancelling a logical request cancels its pending retry timer and blocks repost."
  (let ((kargu--generation 100)
        (kargu-api-retry-max 2)
        (reposted nil)
        (cancelled-timers nil))
    (kargu-http--ensure-logical-request 100)
    (cl-letf (((symbol-function 'kargu--plz-http-status) (lambda (_) 503))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer cancelled-timers)))
              ((symbol-function 'kargu--api-post)
               (lambda (&rest _) (setq reposted t))))
      (kargu--api-on-transport-error
       "https://example.invalid/v1/chat/completions" nil '(("model" . "m"))
       100 #'ignore nil 0 'mock-error)
      (let* ((req (kargu-application-current-request))
             (timer (and req (kargu-logical-request-retry-timer req))))
        (should (kargu-logical-request-p req))
        (should (eq (kargu-logical-request-state req) :retrying))
        (should (timerp timer))
        (kargu-http-cancel)
        (should (memq timer cancelled-timers))
        (should (eq (kargu-logical-request-state req) :cancelled))
        (should-not (kargu-logical-request-retry-timer req))
        ;; Even if the timer callback runs late, it is a no-op
        (kargu-api--retry-post
         100 :url "https://example.invalid/v1/chat/completions"
         :headers nil :payload '(("model" . "m")) :callback #'ignore :attempt 1)
        (should-not reposted)))))
