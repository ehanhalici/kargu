;;; tests/test-confirm.el --- Tests for kargu/ui/confirm -*- lexical-binding: t; -*-

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
           (res nil))
      (kargu-ui-confirm
       :title "⚠️  [Test Prompt]"
       :details "Mock error detail"
       :notice "Pick an option"
       :actions '((:key :retry :label "[Retry]")
                  (:key :stop :label "[Stop]"))
       :chat-buffer chat-buf
       :default-action :stop
       :on-decision (lambda (d) (setq res d)))
      (should (eq res :retry))
      (let ((content (buffer-string)))
        (should (string-match-p "Test Prompt" content))
        (should (string-match-p "Mock error detail" content))
        (should (string-match-p "Retry" content))))))

(ert-deftest kargu-confirm-noninteractive-default-test ()
  "Ensure kargu-ui-confirm returns default action in batch mode without mock."
  (let ((kargu-confirm--mock-decision nil)
        (res nil))
    (kargu-ui-confirm
     :title "⚠️  [Headless Prompt]"
     :actions '((:key :ok :label "[OK]")
                (:key :cancel :label "[Cancel]"))
     :default-action :cancel
     :on-decision (lambda (d) (setq res d)))
    (should (eq res :cancel))))

(ert-deftest kargu-confirm-button-click-answers-once-test ()
  "A click answers through the callback exactly once and never waits."
  (with-temp-buffer
    (let ((kargu-confirm--mock-decision nil)
          (kargu-confirm--pending nil)
          (answers nil)
          (noninteractive nil))
      (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (kargu-ui-confirm
         :title "Ask" :chat-buffer (current-buffer)
         :actions '((:key :yes :label "[Yes]") (:key :no :label "[No]"))
         :on-decision (lambda (d) (push d answers))))
      (should (null answers))
      (should (= (length kargu-confirm--pending) 1))
      (goto-char (point-min))
      (search-forward "[Yes]")
      (backward-char 2)
      (push-button)
      (goto-char (point-min))
      (search-forward "[Yes]")
      (backward-char 2)
      (push-button)
      (should (equal answers '(:yes)))
      (should (null kargu-confirm--pending)))))

(ert-deftest kargu-confirm-options-are-read-only-and-click-once ()
  "Option text cannot be edited, and mouse-1 is bound on the first press."
  (with-temp-buffer
    (kargu-confirm--render-prompt
     (current-buffer) "Ask" "details" "notice"
     '((:key :yes :label "[Yes]") (:key :no :label "[No]"))
     #'ignore)
    (goto-char (kargu-confirm--focus-position (current-buffer)))
    (should (looking-at (regexp-quote "[Yes]")))
    (should (get-text-property (point) 'read-only))
    (should (get-text-property (point) 'front-sticky))
    (let ((map (get-text-property (point) 'keymap)))
      (should (keymapp map))
      (should (commandp (lookup-key map [mouse-1])))
      (should (commandp (lookup-key map [mouse-2])))
      (should (commandp (lookup-key map (kbd "RET")))))
    (goto-char (point-min))
    (search-forward "Ask")
    (should (get-text-property (1- (point)) 'read-only))
    (goto-char (kargu-confirm--focus-position (current-buffer)))
    (should-error (insert "x") :type 'text-read-only)))

(ert-deftest kargu-confirm-place-point-uses-the-chat-buffer ()
  "Point lands on the first option even when another buffer is current."
  (let ((chat (generate-new-buffer " *kargu-confirm-focus*")))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (insert (make-string 8000 ?x))
            (kargu-confirm--render-prompt
             chat "Ask" nil nil
             '((:key :yes :label "[Yes]") (:key :no :label "[No]"))
             #'ignore)
            (goto-char (point-min)))
          (with-temp-buffer
            (insert "short")
            (kargu-confirm--place-point chat)
            (should (< (point-max) 20)))
          (with-current-buffer chat
            (should (looking-at (regexp-quote "[Yes]")))
            (should (> (point) 8000))))
      (kill-buffer chat))))

(ert-deftest kargu-confirm-dismiss-all-silences-callbacks-test ()
  "Dismissing prompts (run stopped) never calls their callbacks."
  (with-temp-buffer
    (let ((kargu-confirm--mock-decision nil)
          (kargu-confirm--pending nil)
          (called nil)
          (noninteractive nil))
      (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (kargu-ui-confirm
         :title "Ask" :chat-buffer (current-buffer)
         :actions '((:key :yes :label "[Yes]"))
         :on-decision (lambda (_d) (setq called t))))
      (kargu-confirm-dismiss-all)
      (should-not called)
      (should (null kargu-confirm--pending)))))

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
        (kargu--loop-handle-response run response)
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
      (cl-letf (((symbol-function 'kargu-circuit-open-p)
                 (lambda () t))
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
