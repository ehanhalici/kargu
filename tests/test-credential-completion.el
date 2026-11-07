;;; test-credential-completion.el --- Actual credential IO completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise real child exit and signal collection independently of task
;; observers.  All credentials are synthetic and all work is local.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/config/worker)

(ert-deftest kargu-credential-completion-cancel-and-timeout-wait-for-child-test ()
  "Observer termination cannot acknowledge a child that is still running."
  (dolist (timeout '(nil 0.03))
    (let* ((deliveries 0) (receipts 0) result signalled process buffer
           (task (kargu-async-start (lambda (&rest _) (cl-incf deliveries))
                                    :owner nil :parent nil :timeout timeout))
           (kill (symbol-function 'kill-process)))
      (unwind-protect
          (progn
            (kargu-config-worker-start
             task "(sleep-for 10)" nil :name "completion-slow"
             :on-quiescent (lambda (value)
                             (cl-incf receipts) (setq result value)
                             (should-not (buffer-live-p buffer))
                             (should (memq (process-status process) '(exit signal)))))
            (setq process (get-process "kargu-completion-slow-worker")
                  buffer (process-buffer process))
            ;; Hold the cancellation signal to separate observation from actual exit.
            (cl-letf (((symbol-function 'kill-process)
                       (lambda (child &optional _group) (setq signalled child))))
              (if timeout
                  (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p task))))
                (kargu-async-cancel task)))
            (should (eq signalled process))
            (should (process-live-p process))
            (should (buffer-live-p buffer))
            (should (zerop receipts))
            (should (= deliveries (if timeout 1 0)))
            (funcall kill process)
            (kargu-bridge-test--wait (lambda () (= receipts 1)))
            (should (eq (kargu-result-err-code result) :cancelled))
            ;; A repeated terminal notification must not redeliver.
            (funcall (process-sentinel process) process "duplicate terminal")
            (should (= receipts 1)))
        (kargu-async-cancel task)
        (when (and process (process-live-p process)) (funcall kill process))
        (when process
          (kargu-bridge-test--wait (lambda () (not (buffer-live-p buffer)))))))))

(ert-deftest kargu-credential-completion-real-plaintext-capture-test ()
  "The actual port reads a local synthetic credential and wipes its buffer."
  (let* ((file (make-temp-file "kargu-completion-auth-"))
         (auth-sources (list file))
         (kargu-config-credential-adapter nil)
         (kargu-config-credential-completion-adapter nil)
         (kargu-config-worker-runner-fn nil)
         (deliveries 0) results
         (task (kargu-async-start (lambda (&rest _) (cl-incf deliveries)) :owner nil :parent nil)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "machine completion.invalid login test password synthetic-completion-key\n"))
          (kargu-config-worker-capture
           "completion-plain" "completion.invalid" task (lambda (value) (push value results)))
          (let* ((process (get-process "kargu-completion-plain-worker"))
                 (buffer (process-buffer process)))
            (kargu-bridge-test--wait (lambda () results))
            (should (memq (process-status process) '(exit signal)))
            (should-not (buffer-live-p buffer))
            (should (= deliveries 1))
            (should (= (length results) 1))
            (should (equal (kargu-result-value (car results)) "synthetic-completion-key"))))
      (kargu-async-cancel task)
      (delete-file file))))

(ert-deftest kargu-credential-completion-custom-late-and-duplicate-test ()
  "Custom cancellation waits for actual completion and suppresses late secrets."
  (let* (completions first-results second-results
         (deliveries 0) (cancels 0)
         (kargu-config-credential-completion-adapter
          (lambda (_provider _host task complete)
            (push complete completions)
            (kargu-async-add-cleanup task (lambda () (cl-incf cancels)))))
         (first (kargu-async-start (lambda (&rest _) (cl-incf deliveries)) :owner nil :parent nil))
         (second (kargu-async-start (lambda (&rest _) (cl-incf deliveries)) :owner nil :parent nil)))
    (unwind-protect
        (progn
          (kargu-config-worker-capture "custom" "first.invalid" first
                                       (lambda (value) (push value first-results)))
          (let ((old (car completions)))
            (kargu-async-cancel first)
            (should (= cancels 1))
            (should-not first-results)
            (should (zerop deliveries))
            (kargu-config-worker-capture "custom" "second.invalid" second
                                         (lambda (value) (push value second-results)))
            (funcall old (kargu-ok "late-first-key"))
            (should (eq (kargu-result-err-code (car first-results)) :cancelled))
            (should-not second-results)
            (funcall old (kargu-ok "duplicate-key"))
            (should (= (length first-results) 1))
            (funcall (car completions) (kargu-ok "second-key"))
            (should (equal (kargu-result-value (car second-results)) "second-key"))
            (should (= deliveries 1))))
      (kargu-async-cancel first)
      (kargu-async-cancel second))))

(ert-deftest kargu-credential-completion-custom-error-is-not-a-join-test ()
  "An adapter throwing after acquisition cannot manufacture completion."
  (let* (complete results cleaned
         (task (kargu-async-start #'ignore :owner nil :parent nil))
         (kargu-config-credential-completion-adapter
          (lambda (_provider _host child callback)
            (setq complete callback)
            (kargu-async-add-cleanup child (lambda () (setq cleaned t)))
            (error "Synthetic private adapter error"))))
    (kargu-config-worker-capture "custom" "custom.invalid" task
                                 (lambda (value) (push value results)))
    (should cleaned)
    (should-not results)
    (funcall complete (kargu-err "synthetic private worker error" :private-code))
    (should (eq (kargu-result-err-code (car results)) :cancelled))
    (should-not (string-match-p "private" (prin1-to-string results)))))

(ert-deftest kargu-credential-completion-unissued-and-legacy-adapters-test ()
  "Unissued captures complete; legacy adapters never grant a quiescence claim."
  (dolist (kind '(no-sources legacy runner closed))
    (let* ((auth-sources nil) results
           (task (kargu-async-start #'ignore :owner nil :parent nil))
           (kargu-config-credential-completion-adapter nil)
           (kargu-config-credential-adapter
            (and (eq kind 'legacy) (lambda (&rest _) (ert-fail "Legacy adapter was issued"))))
           (kargu-config-worker-runner-fn
            (and (eq kind 'runner) (lambda (&rest _) (ert-fail "Legacy runner was issued")))))
      (when (eq kind 'closed) (kargu-async-cancel task))
      (kargu-config-worker-capture "unissued" "unissued.invalid" task
                                   (lambda (value) (push value results)))
      (should (= (length results) 1))
      (should (eq (kargu-result-err-code (car results))
                  (if (eq kind 'closed) :cancelled :auth-unavailable))))))

(ert-deftest kargu-credential-completion-child-failures-clean-and-complete-test ()
  "Startup, decode and output-bound failures never acknowledge usable secrets."
  (dolist (kind '(startup decode oversize))
    (let* (result process buffer
           (task (kargu-async-start #'ignore :owner nil :parent nil))
           (start (symbol-function 'make-process))
           (kargu-config-worker-max-bytes 256))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'make-process)
                       (if (eq kind 'startup)
                           (lambda (&rest _) (error "Synthetic private start error")) start)))
              (kargu-config-worker-start
               task (if (eq kind 'oversize) "(princ (make-string 1024 ?x))" "(princ \"{}\")")
               nil :name "completion-fail"
               :decode (lambda (&rest _) (error "Synthetic private decode error"))
               :on-quiescent (lambda (value) (setq result value))))
            (setq process (get-process "kargu-completion-fail-worker")
                  buffer (and process (process-buffer process)))
            (kargu-bridge-test--wait (lambda () result))
            (should (kargu-err-p result))
            (should-not (string-match-p "private" (prin1-to-string result)))
            (should-not (buffer-live-p buffer)))
        (kargu-async-cancel task)))))

(provide 'tests/test-credential-completion)
;;; test-credential-completion.el ends here
