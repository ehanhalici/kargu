;;; tests/test-loop.el --- Tests for kargu/loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

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

(ert-deftest kargu-loop-doom-approval-grant-3-more-test ()
  "Ensure approving a doom loop prompt grants 3 additional attempts and resets :doom-sigs."
  (let ((run (list :doom-sigs '("debug_step_over\0()" "debug_step_over\0()" "debug_step_over\0()"))))
    ;; Approval branch
    (let ((kargu-loop--mock-doom-decision :approve))
      (should (kargu-loop--request-doom-approval run "debug_step_over" '()))
      (should (null (plist-get run :doom-sigs)))
      ;; After approval, 2 calls don't trigger doom-p, but the 3rd one does
      (let ((sig "debug_step_over\0()"))
        (should-not (kargu--loop-doom-p run sig))
        (should-not (kargu--loop-doom-p run sig))
        (should (kargu--loop-doom-p run sig))))
    ;; Rejection branch
    (let ((kargu-loop--mock-doom-decision :reject))
      (plist-put run :doom-sigs '("debug_step_over\0()" "debug_step_over\0()" "debug_step_over\0()"))
      (should-not (kargu-loop--request-doom-approval run "debug_step_over" '()))
      ;; :doom-sigs is not cleared on rejection
      (should (equal (plist-get run :doom-sigs)
                     '("debug_step_over\0()" "debug_step_over\0()" "debug_step_over\0()"))))))

(ert-deftest kargu-loop-render-doom-approval-prompt-test ()
  "Ensure approval prompt renders buttons and warning banner into chat buffer."
  (with-temp-buffer
    (let ((chat-buf (current-buffer))
          (decision nil))
      (kargu-loop--render-doom-approval-prompt
       chat-buf "debug_step_over" '(("thread_id" . 1))
       (lambda (d) (setq decision d)))
      (let ((content (buffer-string)))
        (should (string-match-p "Tool Repetition Approval" content))
        (should (string-match-p "debug_step_over" content))
        (should (string-match-p "thread_id" content))
        (should (string-match-p "Approve (Grant 3 More)" content))
        (should (string-match-p "Stop Run" content)))
      (should-not decision))))

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

(provide 'tests/test-loop)
;;; test-loop.el ends here
