;;; test-tool-calls.el --- Canonical call identity regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; History and execution must consume the same normalized call identities.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu)

(ert-deftest kargu-tool-call-identities-cover-all-wire-paths-test ()
  "Plain, streamed, native and legacy calls share one identity normalizer."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages nil)) ids)
    (dolist (response
             (list
              '(("choices" . [(("message" . (("tool_calls" . [(("function" . (("name" . "read_file") ("arguments" . "{}"))))]))))]))
              (kargu--accumulate-stream-deltas
               '((("choices" . [(("delta" . (("tool_calls" . [(("index" . 0) ("function" . (("name" . "read_file") ("arguments" . "{}"))))])))
                                 ("finish_reason" . "tool_calls"))]))))
              '(("type" . "message") ("stop_reason" . "tool_use")
                ("content" . [(("type" . "tool_use") ("name" . "read_file") ("input" . :json-empty-object))]))
              '(("choices" . [(("message" . (("function_call" . (("name" . "read_file") ("arguments" . "{}"))))))]))))
      (let* ((normalized (kargu-api-normalize-response response))
             (call (car (kargu-seq-to-list (kargu-response-tool-calls normalized))))
             (id (kargu--loop-call-id call)))
        (should (string-prefix-p "call_kargu_" id))
        (should-not (member id ids))
        (push id ids)
        (kargu-api-store-assistant-turn normalized)
        (should (equal id (kargu-aget (car (kargu-seq-to-list
                                            (kargu-aget (car (last (kargu-history-messages))) "tool_calls"))) "id")))))))

(ert-deftest kargu-tool-call-collisions-and-results-stay-consistent-test ()
  "Duplicate provider IDs and missing IDs cannot create orphan results."
  (let* ((kargu-session--context
          (kargu-test-session-with-history
           :messages '((("role" . "user") ("content" . "Inspect files"))))))
    (dotimes (turn 2)
      (let* ((raw '(("choices" . [(("message" . (("role" . "assistant")
                                                 ("tool_calls" . [(("id" . "provider-id") ("function" . (("name" . "read_file") ("arguments" . "{}"))))
                                                                  (("id" . "provider-id") ("function" . (("name" . "read_file") ("arguments" . "{}"))))
                                                                  (("id" . :json-null) ("function" . (("name" . "read_file") ("arguments" . "{}"))))]))))])))
             (snapshot (copy-tree raw t))
             (normalized (kargu-api-normalize-response raw))
             (calls (kargu-seq-to-list (kargu-response-tool-calls normalized)))
             (ids (mapcar #'kargu--loop-call-id calls)))
        (should (equal raw snapshot))
        (should (= (length (delete-dups (copy-sequence ids))) 3))
        (when (= turn 0) (should (equal (car ids) "provider-id")))
        (when (= turn 1) (should-not (member "provider-id" ids)))
        (kargu-api-store-assistant-turn normalized)
        (dolist (call calls)
          (kargu-history-add-tool-result (kargu--loop-call-id call) "read_file" "Result"))))
    (kargu--validate-history 'keep-assistant-tail)
    (let* ((assistants (seq-filter (lambda (msg) (kargu-aget msg "tool_calls")) (kargu-history-messages)))
           (calls (apply #'append (mapcar (lambda (msg) (kargu-seq-to-list (kargu-aget msg "tool_calls"))) assistants)))
           (results (seq-filter (lambda (msg) (equal (kargu-aget msg "role") "tool")) (kargu-history-messages))))
      (should (= (length calls) 6))
      (should (= (length results) 6))
      (should (= (length (delete-dups (mapcar #'kargu--loop-call-id calls))) 6))
      (should (equal (mapcar #'kargu--loop-call-id calls)
                     (mapcar (lambda (msg) (kargu-aget msg "tool_call_id")) results))))))

(provide 'tests/test-tool-calls)
;;; test-tool-calls.el ends here
