;;; tests/test-confirm.el --- Tests for kargu/ui/confirm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/ui/confirm)
(require 'kargu/loop)
(require 'kargu/loop/tools)
(require 'kargu/loop/ui)
(require 'kargu/loop/machine)
(require 'kargu/api/circuit)

(ert-deftest kargu-confirm-render-prompt-test ()
  "Ensure kargu-confirm--render-prompt renders banner, details, notice, and buttons."
  (with-temp-buffer
    (let ((chat-buf (current-buffer))
          (decision nil))
      (kargu-confirm--render-prompt
       chat-buf
       "⚠️  [Custom Alert]"
       "Detail: curl 28 timeout occurred"
       "Choose an action to proceed:"
       '((:key :retry :label "[↻ Retry]" :help "Retry operation")
         (:key :stop :label "[✗ Stop]" :help "Cancel operation"))
       (lambda (d) (setq decision d)))
      (let ((content (buffer-string)))
        (should (string-match-p "⚠️  \\[Custom Alert\\]" content))
        (should (string-match-p "Detail: curl 28 timeout occurred" content))
        (should (string-match-p "Choose an action to proceed:" content))
        (should (string-match-p "\\[↻ Retry\\]" content))
        (should (string-match-p "\\[✗ Stop\\]" content)))
      (should-not decision))))

(ert-deftest kargu-confirm-mock-decision-and-render-test ()
  "Ensure kargu-ui-confirm respects mock decision while still rendering buffer content."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (kargu-confirm--mock-decision :retry)
           (res (kargu-ui-confirm
                 :title "⚠️  [Test Prompt]"
                 :details "Mock error detail"
                 :notice "Pick an option"
                 :actions '((:key :retry :label "[Retry]")
                            (:key :stop :label "[Stop]"))
                 :chat-buffer chat-buf
                 :default-action :stop)))
      (should (eq res :retry))
      (let ((content (buffer-string)))
        (should (string-match-p "Test Prompt" content))
        (should (string-match-p "Mock error detail" content))
        (should (string-match-p "Retry" content))))))

(ert-deftest kargu-confirm-noninteractive-default-test ()
  "Ensure kargu-ui-confirm returns default action in batch mode without mock."
  (let ((kargu-confirm--mock-decision nil))
    (should (eq (kargu-ui-confirm
                 :title "⚠️  [Headless Prompt]"
                 :actions '((:key :ok :label "[OK]")
                            (:key :cancel :label "[Cancel]"))
                 :default-action :cancel)
                :cancel))))

(ert-deftest kargu-confirm-network-timeout-recovery-retry-test ()
  "Ensure kargu-loop--recover-or-finish resets circuit and retries request on :retry."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (run (list :state 'wait
                      :chat-buffer chat-buf
                      :upstream-retries 3))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :retry)
           (request-called nil)
           (circuit-reset-called nil)
           (err "plz error: curl 28: Operation timeout."))
      (cl-letf (((symbol-function 'kargu-circuit-reset)
                 (lambda () (setq circuit-reset-called t)))
                ((symbol-function 'kargu--loop-request)
                 (lambda (_r _p) (setq request-called t))))
        (kargu-loop--recover-or-finish run err)
        (should circuit-reset-called)
        (should request-called)
        (should (eq (plist-get run :upstream-retries) 0))
        (should (eq (plist-get run :state) 'request))
        (let ((content (buffer-string)))
          (should (string-match-p "Request Interrupted / Network Error" content))
          (should (string-match-p "curl 28: Operation timeout" content))
          (should (string-match-p "Retry Request" content))
          (should (string-match-p "Stop Run" content)))))))

(ert-deftest kargu-confirm-network-timeout-recovery-stop-test ()
  "Ensure kargu-loop--recover-or-finish finishes run with error on :stop."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (run (list :state 'wait
                      :chat-buffer chat-buf
                      :upstream-retries 2))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :stop)
           (finished-status nil)
           (finished-err nil)
           (err "plz error: curl 28: Operation timeout."))
      (cl-letf (((symbol-function 'kargu--loop-finish)
                 (lambda (_r status text)
                   (setq finished-status status)
                   (setq finished-err text))))
        (kargu-loop--recover-or-finish run err)
        (should (eq finished-status :error))
        (should (equal finished-err err))))))

(ert-deftest kargu-confirm-loop-on-error-curl-timeout-test ()
  "Ensure kargu-loop--on-error routes curl 28 timeout through recovery prompt."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (run (list :state 'wait
                      :chat-buffer chat-buf
                      :upstream-retries 0))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :retry)
           (retried nil)
           (response '(("error" . (("message" . "plz error: curl 28: Operation timeout."))))))
      (cl-letf (((symbol-function 'kargu--loop-request)
                 (lambda (_r _p) (setq retried t)))
                ((symbol-function 'kargu-circuit-reset)
                 (lambda () nil)))
        (kargu-loop--on-error run response)
        (should retried)
        (let ((content (buffer-string)))
          (should (string-match-p "curl 28: Operation timeout" content)))))))

(ert-deftest kargu-confirm-circuit-breaker-open-prompt-test ()
  "Ensure tripped circuit breaker prompts for recovery rather than aborting immediately."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (run (list :state 'wait
                      :chat-buffer chat-buf
                      :upstream-retries 4))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :retry)
           (retried nil))
      (cl-letf (((symbol-function 'kargu-circuit-allow-request-p)
                 (lambda () nil))
                ((symbol-function 'kargu-circuit-record-failure)
                 (lambda (_err) nil))
                ((symbol-function 'kargu-circuit-reset)
                 (lambda () nil))
                ((symbol-function 'kargu--loop-request)
                 (lambda (_r _p) (setq retried t))))
        (kargu-loop--retry-upstream run "HTTP 502: Bad Gateway")
        (should retried)
        (let ((content (buffer-string)))
          (should (string-match-p "circuit breaker tripped" content)))))))

(provide 'tests/test-confirm)
;;; test-confirm.el ends here
