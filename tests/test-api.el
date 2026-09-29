;;; tests/test-api.el --- Tests for kargu/api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Ensure the package root is on `load-path` during byte/native compilation.
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

(require 'ert)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)

(declare-function kargu-api-chat-url "kargu/api/wire" (base format))
(declare-function kargu-api-prepare-payload "kargu/api/wire" (payload format))
(declare-function kargu-api-normalize-response "kargu/api/wire" (response))
(declare-function kargu-provider-format-stream-p "kargu/providers/registry" (format))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))

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
  (should (> kargu-api-timeout 0)))

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
    (should (equal (kargu--aget body "system") "be brief"))
    (should (equal (kargu-response-answer-text norm) "hello"))
    (should (equal (kargu-response-finish-reason norm) "stop"))
    (should (equal (kargu-response-finish-reason (kargu-api-normalize-response tool))
                   "tool_calls"))
    (let ((call (car (append (kargu-response-tool-calls
                              (kargu-api-normalize-response tool))
                             nil))))
      (should (equal (kargu--aget (kargu--aget call "function") "name") "read")))))

(ert-deftest kargu-tool-flag-json-false-test ()
  "JSON false is not a true tool flag."
  (require 'kargu/api/tools)
  (should-not (kargu--tool-flag '(("background" . :json-false)) "background"))
  (should (kargu--tool-flag '(("background" . t)) "background"))
  (should-not (kargu--tool-flag '(("staged" . "false")) "staged")))

(ert-deftest kargu-api-opencode-session-header-test ()
  "Test that x-opencode-session header is generated and passed for OpenCode."
  (let ((kargu--session-provider "opencode")
        (kargu--session-id nil))
    (let ((headers (kargu--api-headers "test-key")))
      (should (assoc "x-opencode-session" headers))
      (should (stringp (cdr (assoc "x-opencode-session" headers))))
      (should (> (length (cdr (assoc "x-opencode-session" headers))) 10)))))

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
  "An empty later name does not erase the name; an empty id becomes call_N."
  (let* ((events (list '(("choices" . ((("delta" . (("tool_calls" . ((("index" . 0)
                                                                        ("function" . (("name" . "read_file") ("arguments" . "{\"a\":"))))))))))))
                       '(("choices" . ((("delta" . (("tool_calls" . ((("index" . 0) ("id" . "")
                                                                        ("function" . (("name" . "") ("arguments" . "1}"))))))))
                                        ("finish_reason" . "tool_calls")))))))
         (resp (kargu--accumulate-stream-deltas events))
         (call (car (kargu--aget (kargu--aget (car (kargu--aget resp "choices")) "message") "tool_calls"))))
    (should (equal (kargu--aget (kargu--aget call "function") "name") "read_file"))
    (should (equal (kargu--aget call "id") "call_0"))
    (should (equal (kargu--aget (kargu--aget call "function") "arguments") "{\"a\":1}"))))
