;;; tests/test-loop.el --- Tests for kargu/loop -*- lexical-binding: t; -*-

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
(require 'kargu/loop)
(require 'kargu/loop/tools)
(require 'kargu/loop/machine)

(ert-deftest kargu-loop-doom-p-test ()
  "Ensure kargu--loop-doom-p detects 3 consecutive identical tool calls."
  (let ((run (list :doom-sigs nil))
        (sig "bash\0ls -la"))
    (should-not (kargu--loop-doom-p run sig))
    (should-not (kargu--loop-doom-p run sig))
    (should (kargu--loop-doom-p run sig))))

(ert-deftest kargu-loop-classify-response-test ()
  "Ensure kargu-loop--classify-response identifies tools, answers, and errors correctly."
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
  "Ensure kargu--loop-run-call respects doom approval and rejection."
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
  (let ((kargu--message-history
         (list '(("role" . "system") ("content" . "sys"))
               '(("role" . "user") ("content" . "earlier question"))))
        (kargu--busy nil))
    (kargu--history-add "assistant" "Understood.")
    (kargu--history-add "user" "COMPACTION_REQUEST: summarize")
    (kargu--validate-history)
    (should (= (length kargu--message-history) 4))
    (kargu--history-drop-trailing-compaction)
    (should (= (length kargu--message-history) 3))
    (should (equal (kargu--history-last-role) "assistant"))))

(ert-deftest kargu-system-message-follows-mode-and-compaction-test ()
  "The stored system message is rebuilt when the mode or the compaction overlay changes."
  (let ((kargu--message-history (list '(("role" . "user") ("content" . "hi"))))
        (kargu--system-key nil)
        (kargu--compaction-system nil)
        (mode 'ask))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () mode))
              ((symbol-function 'kargu--get-system-prompt)
               (lambda () (format "SYS %s %s" mode (and kargu--compaction-system t)))))
      (kargu--validate-history)
      (should (equal (kargu-aget (car kargu--message-history) "content") "SYS ask nil"))
      (setq mode 'agent)
      (kargu--validate-history)
      (should (equal (kargu-aget (car kargu--message-history) "content") "SYS agent nil"))
      (setq kargu--compaction-system "compact")
      (kargu--validate-history)
      (should (equal (kargu-aget (car kargu--message-history) "content") "SYS agent t"))
      (setq kargu--compaction-system nil)
      (kargu--validate-history)
      (should (equal (kargu-aget (car kargu--message-history) "content") "SYS agent nil")))))

(ert-deftest kargu-system-message-is-kept-while-nothing-changes-test ()
  "An unchanged prompt input keeps the stored system message untouched."
  (let ((kargu--message-history (list '(("role" . "user") ("content" . "hi"))))
        (kargu--system-key nil)
        (n 0))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'ask))
              ((symbol-function 'kargu--get-system-prompt)
               (lambda () (format "SYS %d" (cl-incf n)))))
      (kargu--validate-history)
      (kargu--validate-history)
      (kargu--validate-history)
      (should (equal (kargu-aget (car kargu--message-history) "content") "SYS 1")))))

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
           (kargu--session-model "openrouter/free-model")
           (kargu--session-provider "openrouter")
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
           (kargu--session-model "openrouter/free-model")
           (kargu--session-provider "openrouter")
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

(provide 'tests/test-loop)
;;; test-loop.el ends here

(ert-deftest kargu-tools-enabled-single-decision-test ()
  "One function answers whether tools are usable; a refusal is per provider/model."
  (let ((kargu--tools-refused (make-hash-table :test #'equal))
        (kargu--model-metadata-table (make-hash-table :test #'equal))
        (kargu--session-provider "openrouter")
        (kargu--session-model "m/one"))
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
