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

(ert-deftest kargu-confirm-dismiss-all-delivers-cancellation-once-test ()
  "Dismissing prompts delivers cancellation once and leaves no pending work."
  (with-temp-buffer
    (let ((kargu-confirm--mock-decision nil)
          (kargu-confirm--pending nil)
          (answers nil)
          (noninteractive nil))
      (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (kargu-ui-confirm
         :title "Ask" :chat-buffer (current-buffer)
         :actions '((:key :yes :label "[Yes]"))
         :on-decision (lambda (decision) (push decision answers))))
      (kargu-confirm-dismiss-all)
      (kargu-confirm-dismiss-all)
      (should (equal answers '(:cancel)))
      (should (null kargu-confirm--pending)))))

(ert-deftest kargu-confirm-concurrent-prompts-remain-actionable-test ()
  "Settling one prompt never removes another prompt's actionable button."
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (let ((kargu-confirm--pending nil) (noninteractive nil) answers)
      (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (dolist (key '(:first :second))
          (kargu-ui-confirm
           :title (symbol-name key) :chat-buffer (current-buffer)
           :actions (list (list :key key :label (format "[%s]" key)))
           :on-decision (lambda (decision) (push decision answers)))))
      (dolist (key '(:first :second))
        (goto-char (point-min))
        (search-forward (format "[%s]" key))
        (backward-char 2)
        (push-button))
      (should (equal (nreverse answers) '(:first :second)))
      (should-not kargu-confirm--pending))))

(ert-deftest kargu-confirm-killing-origin-delivers-cancellation-test ()
  "Closing the origin buffer cannot strand pending confirmation callbacks."
  (let ((buffer (generate-new-buffer " *kargu-confirm-close*"))
        (kargu-confirm--pending nil) (noninteractive nil) answers)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                    ((symbol-function 'recenter) #'ignore))
            (kargu-ui-confirm
             :chat-buffer buffer :actions '((:key :yes :label "[Yes]"))
             :on-decision (lambda (decision) (push decision answers))))
          (kill-buffer buffer)
          (should (equal answers '(:cancel)))
          (should-not kargu-confirm--pending))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kargu-confirm-callback-failure-does-not-strand-other-prompts-test ()
  "One failing cancellation callback cannot block the remaining cancellations."
  (let ((kargu-confirm--pending nil) cancelled)
    (push (kargu-confirm--req-create :on-decision (lambda (_) (setq cancelled t)))
          kargu-confirm--pending)
    (push (kargu-confirm--req-create :on-decision (lambda (_) (error "Broken callback")))
          kargu-confirm--pending)
    (kargu-confirm-dismiss-all)
    (should cancelled)
    (should-not kargu-confirm--pending)))

(ert-deftest kargu-confirm-network-timeout-recovery-retry-test ()
  "Ensure kargu-loop--recover-or-finish resets circuit and retries request on :retry."
  (with-temp-buffer
    (let* ((chat-buf (current-buffer))
           (run (list :state 'wait :chat-buffer chat-buf))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :retry)
           (request-called nil)
           (circuit-reset-called nil)
           (err "plz error: curl 28: Operation timeout."))
      (cl-letf (((symbol-function 'kargu-circuit-reset)
                 (lambda (_provider callback)
                   (setq circuit-reset-called t) (funcall callback nil nil)))
                ((symbol-function 'kargu-circuit-get) (lambda (&rest _) t))
                ((symbol-function 'kargu--loop-request)
                 (lambda (_r _p) (setq request-called t))))
        (kargu-loop--recover-or-finish run err)
        (should circuit-reset-called)
        (should request-called)
        (should-not (plist-member run :upstream-retries))
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
           (run (list :state 'wait :chat-buffer chat-buf))
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
           (run (list :state 'wait :chat-buffer chat-buf))
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
           (run (list :state 'wait :chat-buffer chat-buf))
           (kargu--loop-run run)
           (kargu-confirm--mock-decision :retry)
           (retried nil))
      (cl-letf (((symbol-function 'kargu-circuit-open-p)
                 (lambda () (ert-fail "Loop must not re-evaluate circuit admission")))
                ((symbol-function 'kargu-circuit-reset)
                 (lambda () nil))
                ((symbol-function 'kargu--loop-request)
                 (lambda (_r _p) (setq retried t))))
        (kargu--loop-handle-response run (kargu-err "Circuit breaker OPEN: synthetic refusal" :connection-failed))
        (should retried)
        (let ((content (buffer-string)))
          (should (string-match-p "Circuit breaker OPEN" content)))))))

(ert-deftest kargu-confirm-terminal-upstream-errors-never-create-a-loop-replay-test ()
  "Exhausted transport errors go to recovery, never another timer or request."
  (with-temp-buffer
    (let* ((run (list :state 'wait :chat-buffer (current-buffer)))
           (kargu--loop-run run) recovered)
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (ert-fail "Loop retry timer")))
                ((symbol-function 'kargu--loop-request) (lambda (&rest _) (ert-fail "Loop replay")))
                ((symbol-function 'kargu--api-error-looks-retryable-p)
                 (lambda (&rest _) (ert-fail "Loop inferred HTTP retryability")))
                ((symbol-function 'kargu-loop--recover-or-finish)
                 (lambda (_owner error-data) (push error-data recovered))))
        (dolist (message '("HTTP 429: rate limited" "HTTP 503: overloaded" "upstream error"))
          (let ((response (kargu-err message :server-error)))
            (should (eq (kargu-loop--classify-response run response) 'error))
            (kargu--loop-handle-response run response)))
        (should (= (length recovered) 3))
        (should-not (plist-member run :retry-timer))
        (should-not (plist-member run :upstream-retries))))))

(ert-deftest kargu-loop-obsolete-retry-option-is-the-single-transport-limit-test ()
  "Legacy configuration cannot create a second loop retry budget."
  (let ((kargu-api-retry-max 5))
    (set 'kargu-loop-upstream-retries 2)
    (should (= kargu-api-retry-max 2))
    (should (eq (indirect-variable 'kargu-loop-upstream-retries) 'kargu-api-retry-max))))

(ert-deftest kargu-confirm-native-reset-must-ack-before-manual-replay-test ()
  "Reset ACK, failure, duplicate and stale owner cannot race a manual retry."
  (dolist (outcome '(success failure stale))
    (let* ((run (list :state 'wait :request-provider "captured"))
           (kargu--loop-run run) reply (posts 0) (finishes 0))
      (cl-letf (((symbol-function 'kargu-circuit-get) (lambda (_provider) t))
                ((symbol-function 'kargu-circuit-reset)
                 (lambda (provider callback)
                   (should (equal provider "captured")) (setq reply callback)))
                ((symbol-function 'kargu--loop-request) (lambda (&rest _) (cl-incf posts)))
                ((symbol-function 'kargu--loop-finish) (lambda (&rest _) (cl-incf finishes))))
        (kargu-loop--apply-recovery run "synthetic failure" :retry)
        (should reply) (should (= posts 0)) (should (= finishes 0))
        (when (eq outcome 'stale) (setq kargu--loop-run (list :state 'wait)))
        (funcall reply nil (when (eq outcome 'failure) (kargu-bridge--fault "unavailable")))
        (funcall reply nil nil)
        (should (= posts (if (eq outcome 'success) 1 0)))
        (should (= finishes (if (eq outcome 'failure) 1 0)))))))

(provide 'tests/test-confirm)
;;; test-confirm.el ends here
