;;; test-stream.el --- Stream completion regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Incomplete model replies are errors, not executable tool batches.

;;; Code:

(require 'ert)
(require 'kargu/api/stream)
(require 'kargu/api/sse)
(require 'kargu/api/response)

(ert-deftest kargu-stream-new-tool-fragments-never-share-argument-storage-test ()
  "Separate calls and requests must not append to another call's argument cell."
  (dotimes (_ 2)
    (let ((table (make-hash-table :test #'eql)))
      (kargu--merge-tool-call-fragment table '(("index" . 0) ("function" . (("arguments" . "{\"first\":")))))
      (kargu--merge-tool-call-fragment table '(("index" . 1) ("function" . (("arguments" . "{\"second\":")))))
      (should (equal (kargu-aget (kargu-aget (gethash 0 table) "function") "arguments") "{\"first\":"))
      (should (equal (kargu-aget (kargu-aget (gethash 1 table) "function") "arguments") "{\"second\":")))))

(ert-deftest kargu-stream-malformed-events-do-not-disappear-test ()
  "A terminal marker cannot hide an earlier malformed data event."
  (let ((response (kargu--accumulate-stream-deltas
                   (kargu--sse-parse "data: {broken\n\ndata: [DONE]\n\n"))))
    (should (string-search "Invalid JSON" (kargu-response-error-message response)))
    (should-not (kargu-response-tool-calls response))))

(ert-deftest kargu-stream-incomplete-output-is-never-a-success-test ()
  "Partial text, thought and tool fragments cannot become successful responses."
  (dolist (delta '((("content" . "Partial answer"))
                   (("reasoning_content" . "Partial thought"))
                   (("tool_calls" . [(("index" . 0) ("function" . (("name" . "bash") ("arguments" . "{\"command\":"))))]))))
    (let* ((events (list (list (cons "choices" (vector (list (cons "delta" delta) (cons "finish_reason" :json-null)))))))
           (response (kargu--accumulate-stream-deltas events)))
      (should (string-search "Incomplete SSE response" (kargu-response-error-message response)))
      (should-not (kargu-response-tool-calls response))
      (should-not (kargu-response-text response)))))

(ert-deftest kargu-stream-explicit-completion-paths-test ()
  "A finish reason or DONE marker completes both text and tool responses."
  (let ((delta '(("choices" . [(("delta" . (("content" . "Answer"))))]))))
    (dolist (terminal (list :done '(("choices" . [(("delta" . nil) ("finish_reason" . "stop"))]))))
      (let ((response (kargu--accumulate-stream-deltas (list delta terminal))))
        (should-not (kargu-response-error-message response))
        (should (equal (kargu-response-text response) "Answer")))))
  (let ((response (kargu--accumulate-stream-deltas
                   '((("choices" . [(("delta" . (("tool_calls" . [(("index" . 0) ("function" . (("name" . "read_file") ("arguments" . "{}"))))]))))])) :done))))
    (should (equal (kargu-response-finish-reason response) "tool_calls"))))

(ert-deftest kargu-stream-done-marker-is-preserved-without-ui-delta-test ()
  "Offline and incremental parsing retain DONE but never print it as a delta."
  (should (equal (kargu--sse-parse "data: [DONE]\r\n\r\n") '(:done)))
  (with-temp-buffer
    (let ((process (make-pipe-process :name "kargu-done" :buffer (current-buffer))) events deltas)
      (unwind-protect
          (progn
            (kargu--stream-filter process "data: [DO" (lambda (event) (push event deltas))
                                  (lambda (event) (push event events)))
            (should-not events)
            (kargu--stream-filter process "NE]" (lambda (event) (push event deltas))
                                  (lambda (event) (push event events)))
            (kargu--stream-flush process (lambda (event) (push event deltas))
                                 (lambda (event) (push event events)))
            (should (equal events '(:done)))
            (should-not deltas))
        (delete-process process)))))

(ert-deftest kargu-stream-null-errors-and-invalid-indices-test ()
  "Null error fields are harmless; malformed and conflicting indices fail safely."
  (dolist (error '(nil :json-null :json-false))
    (should-not (kargu--sse-event-error-message (list (cons "error" error)))))
  (should (= (kargu--stream-fragment-index '(("index" . "2"))) 2))
  (let ((table (make-hash-table :test #'eql)))
    (kargu--merge-tool-call-fragment table '(("index" . 0) ("id" . "first")))
    (should-error (kargu--merge-tool-call-fragment table '(("index" . 0) ("id" . "second")))))
  (let ((response (kargu--accumulate-stream-deltas
                   '((("choices" . [(("delta" . (("tool_calls" . [(("index" . "invalid") ("id" . "bad"))]))))])) :done))))
    (should (string-search "Invalid streamed tool-call index" (kargu-response-error-message response)))
    (should-not (kargu-response-tool-calls response))))

(provide 'tests/test-stream)
;;; test-stream.el ends here
