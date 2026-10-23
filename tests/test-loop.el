;;; tests/test-loop.el --- Tests for kargu/loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise loop ownership, cancellation and protocol behavior.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/loop)
(require 'kargu/loop/tools)
(require 'kargu/loop/machine)

(declare-function kargu-test-mode "tests/test-helpers" (mode))
(declare-function kargu-chat-mode "kargu/chat" ())
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))
(declare-function kargu-loop--on-thought "kargu/loop/machine" (run response))

(ert-deftest kargu-loop-tools-rejection-is-specific-and-owned-test ()
  "Tool refusal belongs to the sent model/provider, not a newer selection."
  (should-not (kargu--error-no-tools-support-p "Try disabling your VPN"))
  (let* ((run (list :state 'request)) (kargu--loop-run run)
         (kargu--tools-refused (make-hash-table :test #'equal))
         (provider "old-provider") (model "old-model"))
    (cl-letf (((symbol-function 'kargu--provider-name) (lambda () provider))
              ((symbol-function 'kargu--model) (lambda () model))
              ((symbol-function 'kargu-api-send) #'ignore)
              ((symbol-function 'kargu-state-mode) (lambda () 'ask))
              ((symbol-function 'kargu--loop-request) #'ignore))
      (kargu-loop--send-model run "hello")
      (setq provider "new-provider" model "new-model")
      (kargu-loop--handle-tools-unsupported run "Tools are not supported")
      (should (gethash '("old-provider" . "old-model") kargu--tools-refused))
      (should-not (gethash '("new-provider" . "new-model") kargu--tools-refused)))))

(ert-deftest kargu-loop-thought-callback-error-never-redelivers-test ()
  "Callback arity is inspected before delivery, not guessed from its errors."
  (let* ((count 0)
         (run (list :on-delta (lambda (&rest _)
                               (cl-incf count)
                               (signal 'wrong-number-of-arguments '(broken 2)))))
         (kargu--loop-run run)
         (event '(("choices" . [(("delta" . (("reasoning_content" . "think"))))]))))
    (kargu--loop-forward-delta run event)
    (should (= count 1))
    (plist-put run :on-delta (lambda (_text) (cl-incf count)))
    (kargu--loop-forward-delta run event)
    (should (= count 2))))

(ert-deftest kargu-loop-overflow-preserves-circuit-failures-test ()
  "A context rejection releases a canary but is not an upstream success."
  (dolist (state '(:closed :half-open))
    (let ((kargu-circuit--state state) (kargu-circuit--failure-count 2)
          (kargu-circuit--probe-inflight t))
      (cl-letf (((symbol-function 'kargu--loop-start-compact) (lambda (&rest _) t)))
        (kargu-loop--on-overflow nil nil)
        (should (eq kargu-circuit--state state))
        (should (= kargu-circuit--failure-count 2))
        (should-not kargu-circuit--probe-inflight)))))

(ert-deftest kargu-loop-response-continuation-failure-closes-only-its-run-test ()
  "A failing response continuation ends its run but never cancels a new owner."
  (dolist (replace-owner '(nil t))
    (let* ((run (list :state 'request :iterations 0))
           (new-run (list :state 'wait))
           (kargu--loop-run run) (kargu--busy nil) (kargu--generation 100)
           (kargu--current-process nil) held reports)
      (plist-put run :on-finish (lambda (report) (push report reports)))
      (cl-letf (((symbol-function 'kargu-api-send)
                 (lambda (_prompt callback &rest _) (setq held callback)))
                ((symbol-function 'kargu--loop-handle-response)
                 (lambda (_run _response)
                   (when replace-owner
                     (setq kargu--loop-run new-run kargu--generation 200
                           kargu--busy t kargu--current-process 'new-process))
                   (error "Response handler failed"))))
        (kargu-loop--send-model run "hello")
        (funcall held nil)
        (cond
         (replace-owner
          (should (eq kargu--loop-run new-run))
          (should (= kargu--generation 200))
          (should kargu--busy)
          (should (eq kargu--current-process 'new-process))
          (should-not reports))
         (t
          (should-not (kargu-loop-running-p))
          (should-not kargu--busy)
          (should (= (length reports) 1))
          (should (eq (plist-get (car reports) :status) :error))
          (should (equal (plist-get (car reports) :error) "Response handler failed"))))))))

(ert-deftest kargu-loop-synchronous-startup-failure-releases-run-test ()
  "An initial request exception closes its run and permits another submission."
  (let ((kargu--loop-run nil) (kargu--busy nil) (kargu--generation 80) reports)
    (kargu-test-mode 'ask)
    (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
              ((symbol-function 'kargu-prompt-wrap-user) #'identity)
              ((symbol-function 'kargu--loop-request)
               (lambda (_run _prompt)
                 (cl-incf kargu--generation) (setq kargu--busy t)
                 (error "Initial request failed"))))
      (dotimes (_ 2)
        (kargu-loop-send "Hello" nil (lambda (report) (push report reports)))
        (should-not (kargu-loop-running-p))
        (should-not (plist-get (kargu-session-snapshot) :active))
        (should-not kargu--busy)
        (should (eq (kargu-state-status) :error)))
      (should (= (length reports) 2))
      (should (equal (plist-get (car reports) :error) "Initial request failed")))))

(ert-deftest kargu-loop-prompt-failure-never-publishes-a-run-test ()
  "An asynchronously prepared prompt failure releases admission without sending."
  (let ((kargu--loop-run nil) (kargu--busy nil) reported)
    (kargu-test-mode 'ask)
    (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
              ((symbol-function 'kargu-prompt-wrap-user) (lambda (_) (error "Prompt failed"))))
      (kargu-loop-send "Hello" nil (lambda (report) (setq reported report)))
      (should-not (kargu-loop-running-p))
      (should (eq (plist-get reported :status) :error))
      (should-not (plist-get reported :request-started)))))

(ert-deftest kargu-loop-missing-diagnostics-never-mean-clean-test ()
  "Nil diagnostics neither crash verification nor claim that the edit passed."
  (cl-letf (((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_) nil)))
    (let* ((section (kargu--loop-diag-section "missing.el" nil nil))
           (report (kargu--loop-compose-verified "Edited" (list section) 0 0)))
      (should (= (plist-get section :errors) 0))
      (should (string-search "diagnostics unavailable" report))
      (should (string-search "Verification incomplete" report))
      (should-not (string-search "Verification passed" report)))))

(ert-deftest kargu-loop-doom-p-test ()
  "Ensure `kargu--loop-doom-p' detects 3 consecutive identical tool calls."
  (let ((run (list :doom-sigs nil))
        (sig "bash\0ls -la"))
    (should-not (kargu--loop-doom-p run sig))
    (should-not (kargu--loop-doom-p run sig))
    (should (kargu--loop-doom-p run sig))))

(ert-deftest kargu-loop-classify-response-test ()
  "Ensure response classification identifies tools, answers and errors."
  (let* ((run (list :state 'wait))
         (kargu--loop-run run)
        (tool-resp '(("choices" . ((("index" . 0)
                                    ("message" . (("role" . "assistant")
                                                  ("tool_calls" . ((("id" . "c1")
                                                                    ("function" . (("name" . "bash"))))))))
                                    ("finish_reason" . "tool_calls"))))))
        (ans-resp '(("choices" . ((("index" . 0)
                                   ("message" . (("role" . "assistant")
                                                 ("content" . "all done")))
                                   ("finish_reason" . "stop"))))))
        (err-resp '(("error" . (("message" . "rate limit exceeded"))))))
    (should (eq (kargu-loop--classify-response run tool-resp) 'tools))
    (should (eq (kargu-loop--classify-response run ans-resp) 'answer))
    (should (eq (kargu-loop--classify-response run err-resp) 'error))
    ;; Test length classification respecting run-specific :max-iterations
    (let ((len-resp '(("choices" . ((("index" . 0)
                                     ("message" . (("role" . "assistant")
                                                   ("content" . "partial")))
                                     ("finish_reason" . "length"))))))
          (continued-run (list :state 'wait
                               :iterations kargu-max-iterations
                               :max-iterations (+ kargu-max-iterations 5)
                               :length-continues 0)))
      (let ((kargu--loop-run continued-run))
        (should (eq (kargu-loop--classify-response continued-run len-resp) 'length))))))

(ert-deftest kargu-loop-tool-cacheable-p-test ()
  "Ensure debug stepping, execution, and bash tools are excluded from turn batch caching."
  (should-not (kargu-loop--tool-cacheable-p "debug_step_over"))
  (should-not (kargu-loop--tool-cacheable-p "debug_step_in"))
  (should-not (kargu-loop--tool-cacheable-p "debug_step_out"))
  (should-not (kargu-loop--tool-cacheable-p "debug_continue"))
  (should-not (kargu-loop--tool-cacheable-p "debug_eval"))
  (should-not (kargu-loop--tool-cacheable-p "debug_pause"))
  (should-not (kargu-loop--tool-cacheable-p "debug_toggle_breakpoint"))
  (should-not (kargu-loop--tool-cacheable-p "bash"))
  ;; Readonly and query tools should be cacheable
  (should (kargu-loop--tool-cacheable-p "read_file"))
  (should (kargu-loop--tool-cacheable-p "read_file_symbols"))
  (should (kargu-loop--tool-cacheable-p "grep_search"))
  (should (kargu-loop--tool-cacheable-p "lsp_definitions")))

(defun kargu-test-doom-verdict (run decision)
  "Ask the doom approval for RUN under mock DECISION; return the verdict."
  (let ((kargu-loop--mock-doom-decision decision)
        (verdict :unanswered))
    (kargu-loop--request-doom-approval
     run "debug_step_over" '() (lambda (ok) (setq verdict ok)))
    verdict))

(ert-deftest kargu-loop-doom-approval-grant-3-more-test ()
  "Ensure approving a doom loop prompt grants 3 additional attempts and resets :doom-sigs."
  (let* ((sig "debug_step_over\0()")
         (run (list :doom-sigs (list sig sig sig)))
         (kargu--loop-run run))
    (should (eq (kargu-test-doom-verdict run :approve) t))
    (should (null (plist-get run :doom-sigs)))
    (should-not (kargu--loop-doom-p run sig))
    (should-not (kargu--loop-doom-p run sig))
    (should (kargu--loop-doom-p run sig))
    (plist-put run :doom-sigs (list sig sig sig))
    (should (null (kargu-test-doom-verdict run :reject)))
    (should (equal (plist-get run :doom-sigs) (list sig sig sig)))))

(ert-deftest kargu-loop-doom-sigs-stay-bounded-test ()
  "The signature history never grows past the three that doom detection reads."
  (let ((run (list :doom-sigs nil)))
    (dotimes (i 20)
      (kargu--loop-doom-p run (format "tool\0%d" i)))
    (should (= (length (plist-get run :doom-sigs)) 3))))

(ert-deftest kargu-loop-doom-approval-renders-prompt-test ()
  "The approval prompt shows the banner, tool, arguments and both buttons."
  (with-temp-buffer
    (let* ((run (list :chat-buffer (current-buffer)))
           (kargu--loop-run run)
           (kargu-loop--mock-doom-decision :approve))
      (kargu-loop--request-doom-approval
       run "debug_step_over" '(("thread_id" . 1)) #'ignore)
      (let ((content (buffer-string)))
        (should (string-match-p "Tool Repetition Approval" content))
        (should (string-match-p "debug_step_over" content))
        (should (string-match-p "thread_id" content))
        (should (string-match-p "Approve (Grant 3 More)" content))
        (should (string-match-p "Stop Run" content))))))

(ert-deftest kargu-loop-run-call-doom-flow-test ()
  "Ensure `kargu--loop-run-call' respects doom approval and rejection."
  (let* ((sig (kargu--loop-tool-sig "debug_step_over" nil))
         (call '(("id" . "call_1")
                 ("function" . (("name" . "debug_step_over")
                                ("arguments" . nil)))))
         (run-approved (list :state 'wait
                             :doom-sigs (list sig sig)))
         (executed nil))
    (cl-letf (((symbol-function 'kargu-execute-tool)
               (lambda (_name _args cb)
                 (setq executed t)
                 (funcall cb "step ok")))
              ((symbol-function 'kargu-loop--gate-tool)
               (lambda (_name) nil))
              ((symbol-function 'kargu--loop-after-tool)
               (lambda (_run _id _name _res _q) nil)))
      ;; When approved: executes tool and resets doom-sigs
      (let ((kargu-loop--mock-doom-decision :approve)
            (kargu--loop-run run-approved))
        (kargu--loop-run-call run-approved call nil)
        (should executed)
        (should (null (plist-get run-approved :doom-sigs)))))
    ;; When rejected: triggers doom-stop without executing tool
    (let* ((run-rejected (list :state 'wait
                               :doom-sigs (list sig sig)))
           (stopped nil))
      (cl-letf (((symbol-function 'kargu-execute-tool)
                 (lambda (_name _args _cb)
                   (error "Should not execute tool when doom rejected")))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (_run status _msg)
                   (setq stopped status))))
        (let ((kargu-loop--mock-doom-decision :reject)
              (kargu--loop-run run-rejected))
          (kargu--loop-run-call run-rejected call nil)
          (should (eq stopped :error)))))))

(ert-deftest kargu-loop-doom-approval-after-stop-does-not-run-tool-test ()
  "A late Approve on a stopped run must not execute the tool."
  (let* ((sig (kargu--loop-tool-sig "debug_step_over" nil))
         (call '(("id" . "c1")
                 ("function" . (("name" . "debug_step_over") ("arguments" . nil)))))
         (run (list :state 'wait :doom-sigs (list sig sig)))
         (kargu--loop-run run)
         (executed nil)
         (pending nil))
    (cl-letf (((symbol-function 'kargu-execute-tool)
               (lambda (&rest _) (setq executed t)))
              ((symbol-function 'kargu-loop--request-doom-approval)
               (lambda (_r _n _a cb) (setq pending cb))))
      (kargu--loop-run-call run call nil)
      (should pending)
      (setq kargu--loop-run nil)
      (funcall pending t)
      (should-not executed))))

(ert-deftest kargu-loop-continue-after-stop-sends-nothing-test ()
  "Answering Continue after the run was stopped sends no request."
  (let* ((run (list :iterations 12 :max-iterations 12 :state 'pause))
         (kargu--loop-run nil)
         (sent nil))
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (&rest _) (setq sent t))))
      (kargu-loop--apply-continue-decision run "next" :continue 12 12)
      (should-not sent))))

(ert-deftest kargu-loop-continue-grants-exactly-one-batch-test ()
  "Continue for N more turns yields N model sends, not N-1."
  (let* ((run (list :iterations 0 :max-iterations 3 :state 'request))
         (kargu--loop-run run)
         (kargu-max-iterations 3)
         (sends 0))
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (&rest _) (cl-incf sends)))
              ((symbol-function 'kargu-history-needs-compact-p) (lambda () nil))
              ((symbol-function 'kargu-loop--prompt-continue)
               (lambda (r p) (kargu-loop--apply-continue-decision r p :continue 3 3))))
      (dotimes (_ 6) (kargu--loop-request run "go"))
      (should (= sends 6))
      (should (= (plist-get run :iterations) 6)))))

(ert-deftest kargu-loop-compaction-request-never-merges-into-user-turn-test ()
  "The compaction request stays a separate turn so it can be dropped on failure."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages (list '(("role" . "system") ("content" . "sys"))
			  '(("role" . "user") ("content" . "earlier question")))))
        (kargu--busy nil))
    (kargu--history-add "assistant" "Understood.")
    (kargu--history-add "user" "COMPACTION_REQUEST: summarize")
    (kargu--validate-history)
    (should (= (length (kargu-history-messages)) 4))
    (kargu--history-drop-trailing-compaction)
    (should (= (length (kargu-history-messages)) 3))
    (should (equal (kargu--history-last-role) "assistant"))))

(ert-deftest kargu-system-message-follows-mode-and-compaction-test ()
  "The stored system message is rebuilt when the mode or the compaction overlay changes."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages (list '(("role" . "user") ("content" . "hi")))
          :system-key nil
          :overlay nil))


        (mode 'ask))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () mode))
              ((symbol-function 'kargu--get-system-prompt)
               (lambda (&optional _) (format "SYS %s %s" mode (and (kargu-history-overlay) t)))))
      (kargu--validate-history)
      (should (equal (kargu-aget (car (kargu-history-messages)) "content") "SYS ask nil"))
      (setq mode 'agent)
      (kargu--validate-history)
      (should (equal (kargu-aget (car (kargu-history-messages)) "content") "SYS agent nil"))
      (setf (kargu-history-overlay) "compact")
      (kargu--validate-history)
      (should (equal (kargu-aget (car (kargu-history-messages)) "content") "SYS agent t"))
      (setf (kargu-history-overlay) nil)
      (kargu--validate-history)
      (should (equal (kargu-aget (car (kargu-history-messages)) "content") "SYS agent nil")))))

(ert-deftest kargu-system-message-is-kept-while-nothing-changes-test ()
  "An unchanged prompt input keeps the stored system message untouched."
  (let ((kargu-session--context
         (kargu-test-session-with-history
          :messages (list '(("role" . "user") ("content" . "hi")))
          :system-key nil))

        (n 0))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'ask))
              ((symbol-function 'kargu--get-system-prompt)
               (lambda (&optional _) (format "SYS %d" (cl-incf n)))))
      (kargu--validate-history)
      (kargu--validate-history)
      (kargu--validate-history)
      (should (equal (kargu-aget (car (kargu-history-messages)) "content") "SYS 1")))))

(ert-deftest kargu-loop-continue-prompt-test ()
  "Test loop limit prompt structure and continuation mechanism."
  (let* ((run (list :iterations 12 :max-iterations 12 :state 'request))
         (kargu--loop-run run)
         (chat-buf (get-buffer-create "*kargu-chat-test-limit*"))
         (kargu-loop--mock-continue-decision :continue))
    (plist-put run :chat-buffer chat-buf)
    (unwind-protect
        (progn
          (with-current-buffer chat-buf
            (kargu-chat-mode)
            ;; Mock kargu-api-send so we don't start a real un-mocked request in batch test
            (cl-letf (((symbol-function 'kargu-api-send)
                       (lambda (_prompt _cb &optional _delta) nil)))
              ;; Prompt continue function
              (kargu-loop--prompt-continue run "test prompt")
              (should (string-match-p "Turn limit reached" (buffer-string)))
              (should (string-match-p "Continue" (buffer-string)))
              (should (string-match-p "Stop" (buffer-string))))))
      (kargu-loop-stop "test cleanup")
      (setq kargu--busy nil)
      (when (fboundp 'kargu-state-reset) (kargu-state-reset))
      (kill-buffer chat-buf))))

(ert-deftest kargu-notify-sound-test ()
  "Test audio alert notification dispatch."
  (let ((ding-count 0))
    (cl-letf (((symbol-function 'ding)
               (lambda (&optional _do-not-terminate)
                 (setq ding-count (1+ ding-count)))))
      ;; Enabled: triggers ding
      (let ((kargu-sound-notifications t))
        (kargu-notify 'permission)
        (kargu-notify 'finish)
        (kargu-notify 'limit)
        (should (= ding-count 3)))
      ;; Disabled: stays quiet
      (let ((kargu-sound-notifications nil))
        (kargu-notify 'permission)
        (should (= ding-count 3))))))

(ert-deftest kargu-loop-unsupported-tools-fallback-test ()
  "Test detection and handling of provider endpoints that do not support tools."
  (let ((err-text "HTTP 404: (404) No endpoints found that support tool use. Try disabling \"lsp_project_skeleton\". To learn more about provider routing, visit: https://openrouter.ai/docs/guides/routing/provider-selection"))
    ;; 1. Error string pattern detection
    (should (kargu--error-no-tools-support-p err-text))
    (should (kargu--error-no-tools-support-p "Model does not support tools"))

    ;; 2. In ask mode: falls back to :no-tools t and retries
    (let* ((_ (kargu-test-mode 'ask))
           (kargu--model-metadata-table (make-hash-table :test 'equal))
           (kargu--tools-refused (make-hash-table :test 'equal))
           (kargu-session--context
            (kargu-test-session-with-history :model "openrouter/free-model" :provider "openrouter"))

           (retry-called nil)
           (finish-called nil)
           (run (list :state 'wait :no-tools nil)))
      (cl-letf (((symbol-function 'kargu--loop-request)
                 (lambda (_run _prompt)
                   (setq retry-called t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (&rest _) (setq finish-called t))))
        (kargu-loop--handle-tools-unsupported run err-text)
        (should retry-called)
        (should-not finish-called)
        (should (plist-get run :no-tools))
        (should-not (kargu-model-supports-tools-p "openrouter/free-model"))))

    ;; 3. In agent mode: finishes with descriptive error
    (let* ((_ (kargu-test-mode 'agent))
           (kargu--model-metadata-table (make-hash-table :test 'equal))
           (kargu--tools-refused (make-hash-table :test 'equal))
           (kargu-session--context
            (kargu-test-session-with-history :model "openrouter/free-model" :provider "openrouter"))

           (finish-err nil)
           (run (list :state 'wait :no-tools nil)))
      (cl-letf (((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text)
                   (setq finish-err (cons status text))))
                ((symbol-function 'kargu--loop-request)
                 (lambda (&rest _) nil)))
        (kargu-loop--handle-tools-unsupported run err-text)
        (should (equal (car finish-err) :error))
        (should (string-match-p "does not support tool use" (cdr finish-err)))))))

(ert-deftest kargu-loop-continue-extends-the-cap-test ()
  "Continuing adds one batch to the cap and keeps a tool-free run tool-free."
  (let* ((run (list :iterations 12 :max-iterations 12 :state 'pause :no-tools t))
         (kargu--loop-run run)
         (kargu-max-iterations 12)
         (sent nil))
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (&rest _) (setq sent t))))
      (kargu-loop--apply-continue-decision run "next" :continue 12 12)
      (should sent)
      (should (= (plist-get run :max-iterations) 24))
      (should (eq (plist-get run :no-tools) t)))))

(defun kargu-test--reasoning-response (reason &optional text reasoning)
  "Minimal chat response with finish REASON, TEXT, and REASONING."
  `(("choices" . ((("index" . 0)
                   ("message" . (("role" . "assistant")
                                 ("content" . ,(or text ""))
                                 ("reasoning_content" . ,(or reasoning ""))))
                   ("finish_reason" . ,reason))))))

(ert-deftest kargu-loop-success-is-recorded-only-by-http-test ()
  "A healthy HTTP response resets the breaker once, regardless of loop event."
  (dolist (response (list (kargu-test--reasoning-response "stop" "answer")
                          (kargu-test--reasoning-response "length" "partial")
                          (kargu-test--reasoning-response "stop" nil "reasoning")))
    (let* ((run (list :state 'wait :iterations 1 :max-iterations 3 :no-tools t))
           (kargu--loop-run run) (successes 0)
           (kargu-circuit--state :half-open) (kargu-circuit--probe-inflight t)
           (kargu-circuit--failure-count 3)
           (record (symbol-function 'kargu-circuit-record-success)))
      (cl-letf (((symbol-function 'kargu-circuit-record-success)
                 (lambda (&optional scope) (cl-incf successes) (funcall record scope)))
                ((symbol-function 'kargu--record-usage) #'ignore)
                ((symbol-function 'kargu--loop-request) #'ignore)
                ((symbol-function 'kargu--loop-finish) #'ignore))
        (kargu--api-handle-success
         response (lambda (value) (kargu--loop-handle-response run value)))
        (should (= successes 1))
        (should (eq kargu-circuit--state :closed))
        (should-not kargu-circuit--probe-inflight)
        (should (zerop kargu-circuit--failure-count))))))

(ert-deftest kargu-loop-delta-delivery-supports-optional-and-rest-test ()
  "The declared callback arity chooses one or two arguments without retries."
  (let (seen)
    (dolist (callback (list (lambda (text) (push (list text) seen))
                            (lambda (text &optional kind) (push (list text kind) seen))
                            (lambda (&rest arguments) (push arguments seen))))
      (kargu-loop--deliver-delta callback "text" t))
    (should (equal (nreverse seen) '(("text") ("text" thought) ("text" thought))))))

(ert-deftest kargu-loop-truncated-reasoning-is-never-a-success-test ()
  "A truncated reply stays length and exhausted continuation fails explicitly."
  (let* ((resp (kargu-test--reasoning-response "length" "" "still thinking"))
         (open (list :state 'wait :iterations 2 :length-continues 1))
         (capped (list :state 'wait :iterations 12 :max-iterations 12
                       :length-continues 1)))
    (let ((kargu--loop-run open))
      (should (eq (kargu-loop--classify-response open resp) 'length)))
    (let ((kargu--loop-run capped))
      (should (eq (kargu-loop--classify-response capped resp) 'length)))
    (let ((prompted nil)
          (finished nil))
      (cl-letf (((symbol-function 'kargu-loop--prompt-continue)
                 (lambda (&rest _) (setq prompted t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (&rest _) (setq finished t)))
                ((symbol-function 'kargu-history-needs-compact-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'kargu-circuit-record-success)
                 (lambda (&rest _) nil)))
        (let ((kargu--loop-run capped))
          (kargu-loop--on-length capped resp))
        (should-not prompted)
        (should finished)))))

(ert-deftest kargu-loop-incomplete-responses-finish-as-errors-test ()
  "Repeated truncation and empty-response exhaustion never report :done."
  (dolist (case '(("length" "partial" 3 2)
                  ("length" "" 3 2)
                  ("length" "partial" 1 1)
                  ("stop" "" 3 2)))
    (let* ((posts 0) report
           (kargu-loop-empty-retries 1)
           (run (list :state 'request :iterations 0 :max-iterations (nth 2 case)
                      :no-tools t :on-finish (lambda (value) (setq report value))))
           (kargu--loop-run run))
      (kargu-test-mode 'ask)
      (cl-letf (((symbol-function 'kargu-api-send)
                 (lambda (_prompt callback &rest _)
                   (cl-incf posts)
                   (should (<= posts (nth 3 case)))
                   (funcall callback
                            (kargu-test--reasoning-response (car case) (cadr case)))))
                ((symbol-function 'kargu-history-needs-compact-p) (lambda () nil)))
        (kargu--loop-request run "go")
        (should (= posts (nth 3 case)))
        (should (eq (plist-get report :status) :error))
        (should (stringp (plist-get report :error)))
        (should-not (kargu-loop-running-p))))))

(ert-deftest kargu-loop-repeated-reasoning-stops-at-the-global-turn-cap-test ()
  "Repeated reasoning-only replies pause before a fourth request is sent."
  (let* ((run (list :state 'request :iterations 0 :max-iterations 3 :no-tools t))
         (kargu--loop-run run) (posts 0) (questions 0))
    (kargu-test-mode 'ask)
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (_prompt callback &rest _)
                 (cl-incf posts)
                 (should (<= posts 3))
                 (funcall callback (kargu-test--reasoning-response "stop" nil "reasoning"))))
              ((symbol-function 'kargu-ui-confirm)
               (lambda (&rest _) (cl-incf questions))))
      (kargu--loop-request run "go")
      (should (= posts 3))
      (should (= questions 1))
      (should (eq (plist-get run :state) 'pause)))))

(ert-deftest kargu-loop-stop-reasoning-is-thought-test ()
  "Reasoning with no answer is thought, and the cap asks to continue."
  (let* ((resp (kargu-test--reasoning-response "stop" "" "planning the edit"))
         (early (list :state 'wait :iterations 1))
         (capped (list :state 'wait :iterations 12 :max-iterations 12)))
    (let ((kargu--loop-run early))
      (should (eq (kargu-loop--classify-response early resp) 'thought)))
    (let ((kargu--loop-run capped))
      (should (eq (kargu-loop--classify-response capped resp) 'thought)))
    (let ((prompted nil)
          (finished nil))
      (cl-letf (((symbol-function 'kargu-loop--prompt-continue)
                 (lambda (&rest _) (setq prompted t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (&rest _) (setq finished t)))
                ((symbol-function 'kargu-history-needs-compact-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'kargu-circuit-record-success)
                 (lambda (&rest _) nil)))
        (let ((kargu--loop-run capped))
          (kargu-loop--on-thought capped resp))
        (should prompted)
        (should-not finished)))))

(provide 'tests/test-loop)
;;; test-loop.el ends here

(ert-deftest kargu-tools-enabled-single-decision-test ()
  "One function answers whether tools are usable; a refusal is per provider/model."
  (let ((kargu--tools-refused (make-hash-table :test #'equal))
        (kargu--model-metadata-table (make-hash-table :test #'equal))
        (kargu-session--context
         (kargu-test-session-with-history :provider "openrouter" :model "m/one")))
    (should (kargu-tools-enabled-p))
    (should-not (kargu-tools-enabled-p (list :no-tools t)))
    (kargu-model-mark-tools-refused "m/one")
    (should-not (kargu-tools-enabled-p))
    (should-not (kargu-model-supports-tools-p "m/one"))
    (should (kargu-model-supports-tools-p "m/two"))
    (kargu-model-forget-tools-refusals)
    (should (kargu-tools-enabled-p))))

(ert-deftest kargu-loop-status-shows-the-runs-own-cap-test ()
  (let ((kargu--loop-run (list :state 'wait :iterations 3 :max-iterations 24))
        (kargu-max-iterations 12))
    (should (string-match-p "iteration 3/24" (kargu-loop-status)))))

(ert-deftest kargu-loop-run-captures-immutable-snapshot-and-report-metadata-test ()
  "A run captures mode, session ID, project root and provider/model at start."
  (let ((buf-a (generate-new-buffer " *kargu-run-snap-a*"))
        (buf-b (generate-new-buffer " *kargu-run-snap-b*")))
    (unwind-protect
        (with-current-buffer buf-a
          (setq-local kargu-session--context
                      (kargu-test-session-with-history :provider "openai" :model "gpt-4o"))
          (kargu-state-set-mode 'agent)
          (let* ((run (kargu-loop--new-run "Fix it"))
                 (kargu--loop-run run))
            (should (stringp (plist-get run :id)))
            (should (equal (plist-get run :session-id) (kargu-session-id)))
            (should (eq (plist-get run :mode) 'agent))
            (should (equal (plist-get run :provider) "openai"))
            (should (equal (plist-get run :model) "gpt-4o"))
            ;; Switching to another buffer in ask mode does not alter the active run's tool gate
            (with-current-buffer buf-b
              (setq-local kargu-session--context
                          (kargu-test-session-with-history :provider "groq" :model "llama"))
              (setf (kargu-session-mode-value (kargu-session-context)) 'ask)
              (should (eq (kargu-state-mode) 'ask))
              (should-not (kargu-loop--gate-tool "edit_file")))
            (let ((report (kargu-loop--finish-report run :done "done")))
              (should (equal (plist-get report :run-id) (plist-get run :id)))
              (should (equal (plist-get report :session-id) (plist-get run :session-id)))
              (should (eq (plist-get report :mode) 'agent)))))
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))
