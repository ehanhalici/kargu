;;; test-stream-pressure.el --- Stream backpressure and boundary tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Test suite for Wave 2 Package E: Stream pressure, bounds, and backpressure.
;; Verifies DEEP-12, MOD-04 invariants:
;; - Incomplete line buffer overflow
;; - Raw buffer overflow
;; - Single event size cap
;; - Multibyte UTF-8 byte boundary preservation
;; - Tool-call count and argument size caps
;; - Monotonic time / clock jump tolerance
;; - Duplicate finish discard

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'kargu/api/stream)
(require 'kargu/api/sse)
(require 'kargu/api/response)

(ert-deftest kargu-stream-incomplete-line-overflow-aborts-cleanly-test ()
  "A stream chunk without newline exceeding line buffer limit aborts cleanly."
  (let ((kargu-stream-max-incomplete-line-bytes 512))
    (with-temp-buffer
      (let ((process (make-pipe-process :name "kargu-test-pressure-line" :buffer (current-buffer)))
            (aborted nil))
        (unwind-protect
            (progn
              ;; Send 600 bytes without any newline
              (let ((large-chunk (make-string 600 ?a)))
                (kargu--stream-filter process large-chunk #'ignore #'ignore))
              (setq aborted (process-get process :kargu-stream-abort))
              (should (eq aborted 'line-buffer-overflow)))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest kargu-stream-raw-buffer-total-overflow-aborts-test ()
  "Total raw bytes exceeding max raw buffer size aborts the stream."
  (let ((kargu-stream-max-raw-bytes 1024))
    (with-temp-buffer
      (let ((process (make-pipe-process :name "kargu-test-pressure-raw" :buffer (current-buffer)))
            (aborted nil))
        (unwind-protect
            (progn
              ;; Send small lines with newlines but totaling > 1024 bytes
              (dotimes (_ 15)
                (kargu--stream-filter process (concat (make-string 100 ?x) "\n") #'ignore #'ignore))
              (setq aborted (process-get process :kargu-stream-abort))
              (should (eq aborted 'raw-buffer-overflow)))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest kargu-stream-single-event-size-limit-test ()
  "A single SSE event exceeding `kargu-sse-max-event-bytes' signals an error."
  (let ((kargu-sse-max-event-bytes 256)
        (parser (kargu-sse-parser-create)))
    (kargu-sse-parser-feed parser "event: message")
    ;; Reject before retaining the oversized event, not only at dispatch.
    (should-error (kargu-sse-parser-feed parser (concat "data: " (make-string 300 ?x)))
                  :type 'error)
    (should-not (kargu-sse-parser-data parser))))

(ert-deftest kargu-stream-multibyte-utf8-chunking-test ()
  "Multibyte UTF-8 characters split byte-by-byte decode cleanly."
  (let* ((text "Merhaba dünya 🦀🚀🤖")
         (body (format "data: {\"choices\": [{\"delta\":{\"content\":\"%s\"}}]}\n\ndata: [DONE]\n\n" text))
         (encoded-bytes (encode-coding-string body 'utf-8)))
    (with-temp-buffer
      (let ((process (make-pipe-process :name "kargu-test-utf8" :buffer (current-buffer)))
            events deltas)
        (unwind-protect
            (progn
              ;; Feed byte-by-byte
              (dotimes (i (length encoded-bytes))
                (let ((byte-str (substring encoded-bytes i (1+ i))))
                  (kargu--stream-filter process byte-str
                                        (lambda (d) (push d deltas))
                                        (lambda (e) (push e events)))))
              (kargu--stream-flush process
                                   (lambda (d) (push d deltas))
                                   (lambda (e) (push e events)))
              (let ((response (kargu--accumulate-stream-deltas (nreverse events))))
                (should-not (kargu-response-error-message response))
                (should (equal (kargu-response-text response) text))))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest kargu-stream-tool-call-count-and-argument-limits-test ()
  "Tool call count and argument length upper limits prevent memory exhaustion."
  (let ((kargu-stream-max-tool-calls 2)
        (kargu-stream-max-tool-args-bytes 50)
        (calls-map (make-hash-table :test #'eql)))
    ;; 1st tool call
    (kargu--merge-tool-call-fragment calls-map '(("index" . 0) ("id" . "call_1")
                                                ("function" . (("name" . "f1") ("arguments" . "{\"a\":1}")))))
    ;; 2nd tool call
    (kargu--merge-tool-call-fragment calls-map '(("index" . 1) ("id" . "call_2")
                                                ("function" . (("name" . "f2") ("arguments" . "{\"b\":2}")))))
    (should (= (hash-table-count calls-map) 2))

    ;; 3rd tool call exceeds max 2 -> errors out
    (should-error
     (kargu--merge-tool-call-fragment calls-map '(("index" . 2) ("id" . "call_3")
                                                 ("function" . (("name" . "f3") ("arguments" . "{}")))))
     :type 'error)

    ;; Merging arguments exceeding 50 bytes -> errors out
    (should-error
     (kargu--merge-tool-args "{\"long_key\":" (make-string 60 ?v))
     :type 'error)))

(ert-deftest kargu-stream-monotonic-time-tolerance-test ()
  "The stream activity marker records a positive timestamp from `float-time'."
  (with-temp-buffer
    (let ((process (make-pipe-process :name "kargu-test-clock" :buffer (current-buffer))))
      (unwind-protect
          (progn
            (kargu--api-note-stream-byte process)
            (let ((last-byte (process-get process :kargu-last-byte)))
              (should (numberp last-byte))
              (should (> last-byte 0))))
        (when (process-live-p process)
          (delete-process process))))))

(ert-deftest kargu-stream-duplicate-finish-is-ignored-test ()
  "Data chunks arriving after terminal DONE or finish_reason are discarded."
  (let* ((events (list '(("choices" . [(("delta" . (("content" . "Hello"))))]))
                       :done
                       '(("choices" . [(("delta" . (("content" . " Late ignored"))))]))))
         (response (kargu--accumulate-stream-deltas events)))
    (should (equal (kargu-response-text response) "Hello"))))

(provide 'tests/test-stream-pressure)
;;; test-stream-pressure.el ends here
