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
(require 'kargu/loop/native-owner)

(declare-function kargu-stream-test--server "tests/test-stream"
                  (body stream &optional hold capture capture-headers status headers script))
(declare-function kargu-bridge--client-capabilities "kargu/bridge" ())

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

(defun kargu-credential-completion-test--run (adapter &optional on-started)
  "Run a native prompt needing interop under ADAPTER; return (RESULT HEADERS).
ON-STARTED receives the run task once the request is issued."
  (require 'tests/test-stream)
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          (owner (generate-new-buffer " *kargu-credential-owner*"))
          (root (make-temp-file "kargu-credential-root-" t))
          (kargu-config-credential-completion-adapter adapter)
          headers result failure done
          (server (kargu-stream-test--server
                   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"interop answer\"},\"finish_reason\":\"stop\"}]}"
                   nil nil nil (lambda (value) (setq headers value))))
          (url (format "http://127.0.0.1:%d/v1" (process-contact server :service))))
     (unwind-protect
         (progn
           (should (member "editor_credential_capture" (append (kargu-bridge--client-capabilities) nil)))
           ;; No apikey and no environment: Rust's policy needs an interop credential.
           (let ((kargu-application--bound application))
             (kargu-test-config-publish
              (kargu-config-service-context)
              (list :provider "interop" :providers (list (list "interop" :api url :model "interop-model")))
              "/synthetic/interop" (format "interop|%s" url)))
           (let* ((revision (let ((kargu-application--bound application)) (kargu-config-revision)))
                  (task (with-current-buffer owner
                          (kargu-loop-native-owned-start
                           application
                           (kargu-bridge--object
                            "root" root "mode" "ask" "prompt" (kargu-bridge--object "role" "user" "content" "hi")
                            "tools_enabled" :json-false "tool_limit" 1 "turn_limit" 1
                            "timeout_ms" 4000 "config_revision" revision "policy_revision" 1
                            "connection" (kargu-bridge--object
                                          "url" url "model" "interop-model" "provider" "interop"
                                          "headers" (kargu-bridge--object) "stream" :json-false
                                          "timeouts" (kargu-bridge--object "connect_ms" 1000
                                                                           "first_byte_ms" 2000
                                                                           "deadline_ms" 3000)))
                           (lambda (value error-data) (setq result value failure error-data done t))
                           :owner owner))))
             (if (and on-started (eq (funcall on-started task) :stopped))
                 ;; A stopped run delivers no callback; wait for the actual receipt.
                 (kargu-bridge-test--wait
                  (lambda () (zerop (hash-table-count (kargu-bridge-connection-reverse-cleanups conn)))))
               (kargu-bridge-test--wait (lambda () done)))
             (accept-process-output nil 0.2)
             (list (or result failure) headers)))
       (when (buffer-live-p owner) (kill-buffer owner))
       (delete-process server)
       (delete-directory root t)))))

(ert-deftest kargu-credential-completion-native-run-uses-the-actual-receipt-key-test ()
  "Rust requests the interop credential; only the completed key reaches the wire."
  (let* ((requested nil)
         (outcome (kargu-credential-completion-test--run
                   (lambda (provider host _task complete)
                     (setq requested (list provider host))
                     (run-at-time 0.05 nil complete (kargu-ok "synthetic-interop-key"))))))
    (should (equal requested '("interop" "127.0.0.1")))
    (should (equal (gethash "status" (car outcome)) "completed"))
    (should (string-search "authorization: Bearer synthetic-interop-key" (cadr outcome)))))

(ert-deftest kargu-credential-completion-native-run-reports-unavailable-test ()
  "A source that quiesces without a key ends the run as a credential refusal."
  (let ((outcome (kargu-credential-completion-test--run
                  (lambda (_provider _host _task complete)
                    (run-at-time 0.05 nil complete (kargu-err "No key" :auth-unavailable))))))
    (should (equal (gethash "status" (car outcome)) "credential_unavailable"))
    (should-not (cadr outcome))))

(ert-deftest kargu-credential-completion-native-stop-waits-and-sends-no-key-test ()
  "Stop revokes delivery; the receipt waits for actual completion, without a key."
  (let* (complete cancelled
         (outcome (kargu-credential-completion-test--run
                   (lambda (_provider _host task callback)
                     (setq complete callback)
                     (kargu-async-add-cleanup task (lambda () (setq cancelled t))))
                   (lambda (run)
                     (kargu-bridge-test--wait (lambda () complete))
                     (kargu-async-cancel run)
                     (kargu-bridge-test--wait (lambda () cancelled))
                     ;; The worker finishes later; its key must not be delivered.
                     (run-at-time 0.05 nil complete (kargu-ok "late-interop-key"))
                     :stopped))))
    (should cancelled)
    (should-not (car outcome))
    (should-not (cadr outcome))
    (should-not (string-search "late-interop-key" (prin1-to-string outcome)))))

(provide 'tests/test-credential-completion)
;;; test-credential-completion.el ends here
