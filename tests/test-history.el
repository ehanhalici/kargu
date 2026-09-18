;;; tests/test-history.el --- Tests for kargu/history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/history)

(ert-deftest kargu-history-vector-tool-calls-test ()
  "Ensure kargu--validate-history handles vector tool_calls without crashing (Bug 1 regression)."
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "hi"))
           (("role" . "assistant")
            ("content" . "calling tool")
            ("tool_calls" . [(("id" . "call_vec1")
                              ("type" . "function")
                              ("function" . (("name" . "bash") ("arguments" . "ls"))))]))
           (("role" . "tool")
            ("tool_call_id" . "call_vec1")
            ("name" . "bash")
            ("content" . "file1.txt\nfile2.txt")))))
    ;; Must not signal wrong-type-argument listp
    (should (listp (kargu--validate-history)))
    (should (= (length kargu--message-history) 4))))

(ert-deftest kargu-history-empty-vector-tool-calls-test ()
  "Ensure empty vector tool_calls [] does not trigger false tool branch or crash."
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "hello"))
           (("role" . "assistant")
            ("content" . "done")
            ("tool_calls" . [])))))
    ;; If trailing assistant is stripped (default)
    (let ((kargu-trailing-assistant-fix 'strip))
      (kargu--validate-history)
      (should (= (length kargu--message-history) 2)))))

(ert-deftest kargu-history-completed-tail-alias-test ()
  "Ensure kargu--history-completed-assistant-tail-p alias is defined and functional."
  (should (fboundp 'kargu--history-completed-assistant-tail-p))
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "hello"))
           (("role" . "assistant") ("content" . "finished")))))
    (should (kargu--history-completed-assistant-tail-p))))

(ert-deftest kargu-history-orphan-tool-dropping-test ()
  "Ensure orphan tool results with no prior tool call are dropped."
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "hello"))
           (("role" . "tool")
            ("tool_call_id" . "orphan_call")
            ("name" . "bash")
            ("content" . "orphan output")))))
    (kargu--validate-history)
    ;; Orphan tool message should be dropped
    (should (= (length kargu--message-history) 2))))

(ert-deftest kargu-history-consecutive-user-merge-test ()
  "Ensure consecutive user messages are merged."
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "part 1"))
           (("role" . "user") ("content" . "part 2")))))
    (kargu--validate-history)
    (should (= (length kargu--message-history) 2))
    (should (string-search "part 1\n\npart 2"
                           (alist-get "content" (nth 1 kargu--message-history) nil nil #'equal)))))

(ert-deftest kargu-history-flush-pending-deterministic-test ()
  "Ensure kargu--flush-pending produces synthetic tool results in deterministic call order."
  (let* ((pending (make-hash-table :test #'equal))
         (out-rev nil))
    (puthash "call_b" (cons "tool_b" 2) pending)
    (puthash "call_a" (cons "tool_a" 1) pending)
    (puthash "call_c" (cons "tool_c" 3) pending)
    (setq out-rev (kargu--flush-pending pending out-rev))
    (let ((final-list (nreverse out-rev)))
      (should (= (length final-list) 3))
      (should (equal (alist-get "tool_call_id" (nth 0 final-list) nil nil #'equal) "call_a"))
      (should (equal (alist-get "tool_call_id" (nth 1 final-list) nil nil #'equal) "call_b"))
      (should (equal (alist-get "tool_call_id" (nth 2 final-list) nil nil #'equal) "call_c")))))

(ert-deftest kargu-history-refresh-system-head-non-destructive-test ()
  "Ensure kargu--history-refresh-system-head does not mutate original message in place."
  (let* ((orig-msg '(("role" . "system") ("content" . "original system prompt")))
         (history (list orig-msg))
         (res (kargu--history-refresh-system-head history)))
    (should (equal (alist-get "content" orig-msg nil nil #'equal) "original system prompt"))
    (should-not (eq (car res) orig-msg))))

(ert-deftest kargu-history-refresh-system-head-preserves-stable-system-prompt-test ()
  "Ensure existing system prompt is preserved to maintain exact KV cache prefix."
  (let* ((orig-msg '(("role" . "system") ("content" . "custom session system prompt from yesterday")))
         (history (list orig-msg '(("role" . "user") ("content" . "hello"))))
         (res (kargu--history-refresh-system-head history)))
    ;; The head system prompt should retain its exact saved content
    (should (equal (alist-get "content" (car res) nil nil #'equal)
                   "custom session system prompt from yesterday"))))

(ert-deftest kargu-history-refresh-system-head-force-refresh-test ()
  "Ensure force-refresh flag regenerates system prompt when requested."
  (let* ((orig-msg '(("role" . "system") ("content" . "old system prompt")))
         (history (list orig-msg))
         (res (kargu--history-refresh-system-head history t)))
    (should-not (equal (alist-get "content" (car res) nil nil #'equal)
                       "old system prompt"))))

(provide 'tests/test-history)

;;; test-history.el ends here
