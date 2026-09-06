;;; tests/test-api.el --- Tests for kargu/api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)

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

(provide 'tests/test-api)
;;; test-api.el ends here
