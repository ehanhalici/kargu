;;; tests/test-compact.el --- Tests for history and loop compaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for history and loop compaction.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/history/compact)
(require 'kargu/loop)
(require 'kargu/loop/compact)
(require 'kargu/ui/confirm)

(kargu-ui-confirm-install)

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
	     (let ((kargu-session--context
		    (kargu-test-session-with-history
		     :messages (kargu-compact-test--history 1))))
        (should-not (kargu-history-needs-compact-p)))
	     (let ((kargu-session--context
		    (kargu-test-session-with-history
		     :messages (kargu-compact-test--history 6))))
        (should (> (kargu-history-char-count) 50))
        (should (kargu-history-needs-compact-p))))))

(ert-deftest kargu-history-small-windows-and-structured-cost-test ()
  "A small window wins over the fallback; structured blocks and schemas count."
  (let ((kargu-history-compact-chars 45000)
        (image (make-string 4000 ?a)))
    (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&rest _) 1024)))
      (should (= (kargu-history-compact-threshold) (round (* 1024 3.5 0.70)))))
    (let ((kargu-session--context
           (kargu-test-session-with-history
            :messages (list (list '("role" . "user")
				  (cons "content" (vector (list '("type" . "image_url")
								(cons "image_url" image)))))
			    '(("role" . "assistant")
			      ("tool_calls" . ((("id" . "c1") ("function" . (("arguments" . "large args")))))))))))
      (cl-letf (((symbol-function 'kargu-tool-schema-char-count) (lambda () 123)))
        (should (= (kargu-history-char-count)
                   (+ 123 (length (kargu-json-encode-record (vconcat (kargu-history-messages)))))))
        (should (> (kargu-history-char-count) 4000))))))

(ert-deftest kargu-history-compact-tail-starts-on-a-user-turn-test ()
  "The kept tail never starts on an assistant or a tool result."
  (let ((kargu-history-compact-keep 3)
        (kargu-session--context
         (kargu-test-session-with-history
          :messages (kargu-compact-test--history 5))))
    (let ((tail (kargu-history-compact-tail)))
      (should tail)
      (should (equal (kargu-aget (car tail) "role") "user"))
      (should (equal (kargu-aget (car (last tail)) "content") "answer 5")))))

(ert-deftest kargu-history-apply-compaction-keeps-summary-and-tail-test ()
  "The summary becomes an ack turn and the tail follows it."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages (kargu-compact-test--history 5)
          :overlay "overlay")))
    (kargu-history-apply-compaction
     "the summary"
     (list '(("role" . "user") ("content" . "recent question"))))
    (should-not (kargu-history-overlay))
    (should (equal (kargu-aget (nth 0 (kargu-history-messages)) "role") "system"))
    (should (string-prefix-p "COMPACTION_ACK:" (kargu-aget (nth 1 (kargu-history-messages)) "content")))
    (should (string-search "the summary" (kargu-aget (nth 1 (kargu-history-messages)) "content")))
    (should (equal (kargu-aget (nth 2 (kargu-history-messages)) "role") "assistant"))
    (should (equal (kargu-aget (car (last (kargu-history-messages))) "content") "recent question"))))

(ert-deftest kargu-history-drop-trailing-compaction-test ()
  "A failed compaction request does not stay in the history."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages (append (kargu-compact-test--history 1)
			    (list '(("role" . "user") ("content" . "COMPACTION_REQUEST: summarize")))))))
    (kargu--history-drop-trailing-compaction)
    (should (equal (kargu-aget (car (last (kargu-history-messages))) "content") "answer 1"))))

(ert-deftest kargu-loop-compaction-runs-once-and-is-tool-free-test ()
  "One compaction turn per run; the run is tool-free while it waits."
  (let* ((run (list :state 'request :iterations 1 :max-iterations 10))
         (kargu--loop-run run)
         (kargu-session--context
          (kargu-test-session-with-history
           :messages (kargu-compact-test--history 3)))
         (sent nil) kind)
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (prompt _cb &optional _d debit-kind) (setq sent prompt kind debit-kind)))
              ((symbol-function 'kargu-loop--set-state) (lambda (r s) (plist-put r :state s))))
      (should (kargu--loop-start-compact run "go on"))
      (should sent)
      (should (eq kind :compaction-turn))
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
         (kargu-session--context
          (kargu-test-session-with-history
           :messages (kargu-compact-test--history 3)))
         (resumed nil))
    (cl-letf (((symbol-function 'kargu--loop-request)
               (lambda (_run prompt) (setq resumed prompt))))
      (kargu--loop-handle-compaction
       run '(("choices" . ((("message" . (("content" . "SUMMARY"))))))))
      (should (equal resumed "go on"))
      (should-not (plist-get run :no-tools))
      (should-not (plist-get run :compacting))
      (should (string-search "SUMMARY"
                             (kargu-aget (nth 1 (kargu-history-messages)) "content"))))))

(ert-deftest kargu-loop-compaction-failure-finishes-the-run-test ()
  "An empty summary or an error ends the run with an error and cleans the history."
  (let* ((run (list :state 'compact :compacting t))
         (kargu--loop-run run)
         (kargu-session--context
          (kargu-test-session-with-history
           :messages (append (kargu-compact-test--history 1)
			     (list '(("role" . "user") ("content" . "COMPACTION_REQUEST: x"))))))
         (finished nil))
    (cl-letf (((symbol-function 'kargu--loop-finish)
               (lambda (_run status text) (setq finished (cons status text)))))
      (kargu--loop-handle-compaction
       run '(("choices" . ((("message" . (("content" . ""))))))))
      (should (eq (car finished) :error))
      (should (string-search "empty summary" (cdr finished)))
      (should (equal (kargu-aget (car (last (kargu-history-messages))) "content") "answer 1")))))

(ert-deftest kargu-loop-compaction-timeout-asks-to-retry-test ()
  "A compaction curl timeout asks to retry, and retry sends compaction again."
  (with-temp-buffer
    (let* ((run (list :state 'compact :compacting t :compactions 1
                      :chat-buffer (current-buffer)
                      :saved-no-tools nil :no-tools t))
           (kargu--loop-run run)
           (kargu-session--context
            (kargu-test-session-with-history
             :messages (append (kargu-compact-test--history 1)
			       (list '(("role" . "user")
				       ("content" . "COMPACTION_REQUEST: x"))))))
           (kargu-confirm--mock-decision :retry)
           (sent nil)
           (finished nil)
           (resp (kargu-err "Native API timeout" :timeout)))
      (cl-letf (((symbol-function 'kargu-api-send)
                 (lambda (&rest _) (setq sent t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text) (setq finished (cons status text))))
                ((symbol-function 'kargu-circuit-reset)
                 (lambda (_provider callback) (funcall callback nil nil))))
        (kargu--loop-handle-compaction run resp)
        (should sent)
        (should-not finished)
        (should (plist-get run :compacting))
        (should (string-match-p "Retry Compaction" (buffer-string)))
        (should (string-match-p "Native API timeout" (buffer-string)))))))

(ert-deftest kargu-loop-compaction-timeout-stop-finishes-the-run-test ()
  "Stopping after a compaction timeout ends the run and drops the request."
  (with-temp-buffer
    (let* ((run (list :state 'compact :compacting t :compactions 1
                      :chat-buffer (current-buffer)))
           (kargu--loop-run run)
           (kargu-session--context
            (kargu-test-session-with-history
             :messages (append (kargu-compact-test--history 1)
			       (list '(("role" . "user")
				       ("content" . "COMPACTION_REQUEST: x"))))))
           (kargu-confirm--mock-decision :stop)
           (finished nil))
      (cl-letf (((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text) (setq finished (cons status text)))))
        (kargu--loop-handle-compaction
         run (kargu-err "Native API timeout" :timeout))
        (should (eq (car finished) :error))
        (should (string-search "Native API timeout" (cdr finished)))
        (should (equal (kargu-aget (car (last (kargu-history-messages))) "content")
                       "answer 1"))))))

(ert-deftest kargu-loop-compaction-other-error-finishes-without-asking-test ()
  "A compaction error that is not a timeout still ends the run at once."
  (let* ((run (list :state 'compact :compacting t :compactions 1))
         (kargu--loop-run run)
         (kargu-session--context
          (kargu-test-session-with-history
           :messages (kargu-compact-test--history 1)))
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

(ert-deftest kargu-native-opt-in-disables-legacy-compaction-and-overlay-decisions-test ()
  "Native runs never invoke Elisp loop/compact, history/compact, or prompt overlay."
  (let* ((kargu-history-compact-chars 50)
         (kargu-session--context
          (kargu-test-session-with-history
           :messages (kargu-compact-test--history 6)
           :overlay "LEGACY-OVERLAY"))
         (run (list :state 'request :native-backend t :iterations 0 :max-iterations 10
                    :history (kargu-history-context)))
         (kargu--loop-run run)
         (api-called nil))
    (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&rest _) nil))
              ((symbol-function 'kargu-api-send) (lambda (&rest _) (setq api-called t))))
      (should-not (kargu-history-needs-compact-p))
      (should-not (kargu--loop-compact-allowed-p run))
      (should-not (kargu--loop-start-compact run "continue"))
      (should-not api-called)
      (should (eq (kargu-loop--classify-request run) 'stale))
      (should (eq (kargu-loop--classify-response
                   run '(("error" . (("code" . "context_length_exceeded")
                                     ("message" . "maximum context length exceeded")))))
                  'stale))
      (should-not (equal (kargu--get-system-prompt (kargu-history-context))
                         "LEGACY-OVERLAY")))))

(ert-deftest kargu-native-error-never-triggers-legacy-summary-replay-test ()
  "A native run error finishes cleanly without starting legacy compaction replay."
  (let* ((kargu-session--context
          (kargu-test-session-with-history
           :messages (kargu-compact-test--history 3)))
         (run (list :state 'wait :native-backend t :iterations 0 :max-iterations 10))
         (kargu--loop-run run)
         (legacy-compact-started nil)
         (finished nil))
    (cl-letf (((symbol-function 'kargu--loop-start-compact)
               (lambda (&rest _) (setq legacy-compact-started t)))
              ((symbol-function 'kargu--loop-finish)
               (lambda (_r status text) (setq finished (cons status text)))))
      (let ((result (kargu-bridge--object
                     "status" "failed"
                     "accounting" (kargu-bridge--object
                                   "budget" (kargu-bridge--object
                                             "requests_spent" 2
                                             "compactions_spent" 1)
                                   "failure" (kargu-bridge--object
                                              "code" "context_overflow")))))
        (kargu-loop-native--finish run result nil)
        (should-not legacy-compact-started)
        (should (eq (car finished) :error))
        (should (= (plist-get run :iterations) 2))
        (should (= (plist-get run :compactions) 1))))))

(provide 'tests/test-compact)
;;; test-compact.el ends here
