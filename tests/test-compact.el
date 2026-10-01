;;; tests/test-compact.el --- Tests for history and loop compaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/history/compact)
(require 'kargu/loop)
(require 'kargu/loop/compact)

(defun kargu-compact-test--history (n)
  "A system message plus N user/assistant pairs."
  (cons '(("role" . "system") ("content" . "sys"))
        (cl-loop for i from 1 to n
                 append (list `(("role" . "user") ("content" . ,(format "question %d" i)))
                              `(("role" . "assistant") ("content" . ,(format "answer %d" i)))))))

(ert-deftest kargu-history-compact-threshold-uses-the-floor-without-a-window-test ()
  "No known context window means the configured floor, never a guess."
  (let ((kargu-history-compact-chars 1234))
    (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&rest _) nil)))
      (should (= (kargu-history-compact-threshold) 1234)))
    (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&rest _) 200000)))
      (should (= (kargu-history-compact-threshold) (round (* 200000 3.5 0.70)))))))

(ert-deftest kargu-history-needs-compact-only-when-large-and-long-test ()
  "Both the size and the message count must be over their limits."
  (let ((kargu-history-compact-chars 50))
    (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&rest _) nil)))
      (let ((kargu--message-history (kargu-compact-test--history 1)))
        (should-not (kargu-history-needs-compact-p)))
      (let ((kargu--message-history (kargu-compact-test--history 6)))
        (should (> (kargu-history-char-count) 50))
        (should (kargu-history-needs-compact-p))))))

(ert-deftest kargu-history-compact-tail-starts-on-a-user-turn-test ()
  "The kept tail never starts on an assistant or a tool result."
  (let ((kargu-history-compact-keep 3)
        (kargu--message-history (kargu-compact-test--history 5)))
    (let ((tail (kargu-history-compact-tail)))
      (should tail)
      (should (equal (kargu-aget (car tail) "role") "user"))
      (should (equal (kargu-aget (car (last tail)) "content") "answer 5")))))

(ert-deftest kargu-history-apply-compaction-keeps-summary-and-tail-test ()
  "The summary becomes an ack turn and the tail follows it."
  (let ((kargu--message-history (kargu-compact-test--history 5))
        (kargu--compaction-system "overlay"))
    (kargu-history-apply-compaction
     "the summary"
     (list '(("role" . "user") ("content" . "recent question"))))
    (should-not kargu--compaction-system)
    (should (equal (kargu-aget (nth 0 kargu--message-history) "role") "system"))
    (should (string-prefix-p "COMPACTION_ACK:" (kargu-aget (nth 1 kargu--message-history) "content")))
    (should (string-search "the summary" (kargu-aget (nth 1 kargu--message-history) "content")))
    (should (equal (kargu-aget (nth 2 kargu--message-history) "role") "assistant"))
    (should (equal (kargu-aget (car (last kargu--message-history)) "content") "recent question"))))

(ert-deftest kargu-history-drop-trailing-compaction-test ()
  "A failed compaction request does not stay in the history."
  (let ((kargu--message-history
         (append (kargu-compact-test--history 1)
                 (list '(("role" . "user") ("content" . "COMPACTION_REQUEST: summarize"))))))
    (kargu--history-drop-trailing-compaction)
    (should (equal (kargu-aget (car (last kargu--message-history)) "content") "answer 1"))))

(ert-deftest kargu-loop-compaction-runs-once-and-is-tool-free-test ()
  "One compaction turn per run; the run is tool-free while it waits."
  (let* ((run (list :state 'request :iterations 1 :max-iterations 10))
         (kargu--loop-run run)
         (kargu--message-history (kargu-compact-test--history 3))
         (sent nil))
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (prompt _cb &optional _d) (setq sent prompt)))
              ((symbol-function 'kargu-loop--set-state) (lambda (r s) (plist-put r :state s))))
      (should (kargu--loop-start-compact run "go on"))
      (should sent)
      (should (plist-get run :compacting))
      (should (plist-get run :no-tools))
      (should (= (plist-get run :iterations) 2))
      (should-not (kargu--loop-start-compact run "again")))))

(ert-deftest kargu-loop-compaction-summary-resumes-the-run-test ()
  "An answer applies the summary, restores tools and resumes the original work."
  (let* ((run (list :state 'compact :compacting t :saved-no-tools nil :no-tools t
                    :resume-prompt "go on"
                    :compact-tail (list '(("role" . "user") ("content" . "tail")))))
         (kargu--loop-run run)
         (kargu--message-history (kargu-compact-test--history 3))
         (resumed nil))
    (cl-letf (((symbol-function 'kargu--loop-request)
               (lambda (_run prompt) (setq resumed prompt))))
      (kargu--loop-handle-compaction
       run '(("choices" . ((("message" . (("content" . "SUMMARY"))))))))
      (should (equal resumed "go on"))
      (should-not (plist-get run :no-tools))
      (should-not (plist-get run :compacting))
      (should (string-search "SUMMARY"
                             (kargu-aget (nth 1 kargu--message-history) "content"))))))

(ert-deftest kargu-loop-compaction-failure-finishes-the-run-test ()
  "An empty summary or an error ends the run with an error and cleans the history."
  (let* ((run (list :state 'compact :compacting t))
         (kargu--loop-run run)
         (kargu--message-history
          (append (kargu-compact-test--history 1)
                  (list '(("role" . "user") ("content" . "COMPACTION_REQUEST: x")))))
         (finished nil))
    (cl-letf (((symbol-function 'kargu--loop-finish)
               (lambda (_run status text) (setq finished (cons status text)))))
      (kargu--loop-handle-compaction
       run '(("choices" . ((("message" . (("content" . ""))))))))
      (should (eq (car finished) :error))
      (should (string-search "empty summary" (cdr finished)))
      (should (equal (kargu-aget (car (last kargu--message-history)) "content") "answer 1")))))

(ert-deftest kargu-loop-compaction-timeout-asks-to-retry-test ()
  "A compaction curl timeout asks to retry, and retry sends compaction again."
  (with-temp-buffer
    (let* ((run (list :state 'compact :compacting t :compactions 1
                      :chat-buffer (current-buffer)
                      :saved-no-tools nil :no-tools t))
           (kargu--loop-run run)
           (kargu--message-history
            (append (kargu-compact-test--history 1)
                    (list '(("role" . "user")
                            ("content" . "COMPACTION_REQUEST: x")))))
           (kargu-confirm--mock-decision :retry)
           (sent nil)
           (finished nil)
           (resp '(("error" . (("message" . "plz error: curl 28: Operation timeout."))))))
      (cl-letf (((symbol-function 'kargu-api-send)
                 (lambda (&rest _) (setq sent t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text) (setq finished (cons status text))))
                ((symbol-function 'kargu-circuit-reset) #'ignore))
        (kargu--loop-handle-compaction run resp)
        (should sent)
        (should-not finished)
        (should (plist-get run :compacting))
        (should (string-match-p "Retry Compaction" (buffer-string)))
        (should (string-match-p "curl 28: Operation timeout" (buffer-string)))))))

(ert-deftest kargu-loop-compaction-timeout-stop-finishes-the-run-test ()
  "Stopping after a compaction timeout ends the run and drops the request."
  (with-temp-buffer
    (let* ((run (list :state 'compact :compacting t :compactions 1
                      :chat-buffer (current-buffer)))
           (kargu--loop-run run)
           (kargu--message-history
            (append (kargu-compact-test--history 1)
                    (list '(("role" . "user")
                            ("content" . "COMPACTION_REQUEST: x")))))
           (kargu-confirm--mock-decision :stop)
           (finished nil))
      (cl-letf (((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text) (setq finished (cons status text)))))
        (kargu--loop-handle-compaction
         run '(("error" . (("message" . "plz error: curl 28: Operation timeout.")))))
        (should (eq (car finished) :error))
        (should (string-search "curl 28" (cdr finished)))
        (should (equal (kargu-aget (car (last kargu--message-history)) "content")
                       "answer 1"))))))

(ert-deftest kargu-loop-compaction-other-error-finishes-without-asking-test ()
  "A compaction error that is not a timeout still ends the run at once."
  (let* ((run (list :state 'compact :compacting t :compactions 1))
         (kargu--loop-run run)
         (kargu--message-history (kargu-compact-test--history 1))
         (finished nil)
         (asked nil))
    (cl-letf (((symbol-function 'kargu--loop-finish)
               (lambda (_run status text) (setq finished (cons status text))))
              ((symbol-function 'kargu-ui-confirm)
               (lambda (&rest _) (setq asked t))))
      (kargu--loop-handle-compaction
       run '(("error" . (("message" . "HTTP 400: bad request")))))
      (should-not asked)
      (should (eq (car finished) :error))
      (should (string-search "HTTP 400" (cdr finished))))))

(provide 'tests/test-compact)
;;; test-compact.el ends here
