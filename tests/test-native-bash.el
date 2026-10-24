;;; test-native-bash.el --- Shell tool native cutover contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The former Elisp-runner tests now exercise the real approved Rust pipe.

;;; Code:

(require 'tests/test-helpers)
(require 'tests/test-bridge-jobs)
(require 'kargu/tools/bash)
(require 'kargu/tools/bash/native)

(defmacro kargu-bash-test--with-core (&rest body)
  "Run BODY in an explicitly approved, temporary native shell project."
  (declare (indent 0) (debug t))
  `(kargu-bridge-test--with-core
     (with-temp-buffer
       (let* ((root (file-name-as-directory (file-truename (make-temp-file "kargu-bash-native-" t))))
              (default-directory root) (kargu-permission--override-root root)
              (kargu-job--services (make-hash-table :test #'equal))
              (kargu-bash--processes (make-hash-table :test #'equal))
              (kargu-bash--counter 0) (kargu-bash--active-async-proc nil))
         (kargu-test-mode 'agent)
         (unwind-protect
             (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve)) ,@body)
           (let ((views (mapcar #'kargu-bash--job-buffer (hash-table-values kargu-bash--processes))))
             (kargu-job-services-reset)
             (kargu-bridge-test--wait (lambda () (= 0 (hash-table-count (kargu-bridge-connection-jobs conn)))))
             (dolist (view views) (when (buffer-live-p view) (kill-buffer view))))
           (delete-directory root t))))))

(defun kargu-bash-test--job ()
  "Return the only registered shell view in this isolated fixture."
  (should (= 1 (hash-table-count kargu-bash--processes)))
  (car (hash-table-values kargu-bash--processes)))

(ert-deftest kargu-bash-native-environment-first-entry-and-unset-test ()
  "Explicit environment capture preserves Emacs duplicate/unset semantics."
  (let* ((process-environment '("FIRST=first" "FIRST=second" "UNSET" "UNSET=hidden"))
         (environment (kargu-bridge-command--environment)))
    (should (= 1 (hash-table-count environment)))
    (should (equal "first" (gethash "FIRST" environment)))
    (should-not (gethash "UNSET" environment))))

(ert-deftest kargu-bash-native-view-keeps-reader-state-and-user-edit-flag-test ()
  "Output is bounded without moving point, widening the view or hiding user edits."
  (with-temp-buffer
    (insert "first\nsecond\n")
    (goto-char 3)
    (narrow-to-region 1 6)
    (let ((job (kargu-bash--make-job :buffer (current-buffer) :limit 24)))
      (kargu-bash-native--append job "😀😀" nil)
      (should (= (point) 3))
      (should (= (point-min) 1))
      (should (= (point-max) 6))
      (should (buffer-modified-p))
      (widen)
      (should (<= (string-bytes (buffer-string)) 24)))))

(ert-deftest kargu-bash-native-unavailable-never-replays-in-elisp-test ()
  "A failed native start reports failure instead of invoking the old runner."
  (kargu-bash-test--with-core
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (done) (funcall done nil (kargu-bridge--fault "unavailable")) #'ignore))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Unexpected Elisp fallback"))))
      (let ((result (kargu-test-await (lambda (done) (kargu-bash-run "printf never" nil nil done)))))
        (should (string-search "ERROR:" result))
        (should (eq (kargu-bash--job-state (kargu-bash-test--job)) :failed))))))

(ert-deftest kargu-bash-native-cancel-before-startup-does-not-leave-live-view-test ()
  "Cancelling a pending startup closes only its task and reports no fake process exit."
  (kargu-bash-test--with-core
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (_done) #'ignore)))
      (let ((task (kargu-bash-run "printf never" nil nil (lambda (_) (ert-fail "Cancelled callback")))))
        (kargu-async-cancel task)
        (should (eq (kargu-bash--job-state (kargu-bash-test--job)) :failed))
        (should-not (kargu-bash--job-handle (kargu-bash-test--job)))))))

(ert-deftest kargu-bash-run-async-callback-test ()
  "Shell argv, merged stderr and Unicode survive the native tool path."
  (kargu-bash-test--with-core
    (let ((result (kargu-test-await (lambda (done) (kargu-bash-run "printf 'async_ğ😀'; printf stderr >&2" nil nil done)))))
      (should (string-search "exit 0" result))
      (should (string-search "async_ğ😀stderr" result))
      (should (kargu-bridge-job-p (kargu-bash--job-handle (kargu-bash-test--job)))))))

(ert-deftest kargu-execute-tool-async-bash-test ()
  "The existing tool gate and schema deliver a real native Bash result."
  (kargu-bash-test--with-core
    (let ((result (kargu-test-await
                   (lambda (done) (kargu-execute-tool "bash" '(("command" . "printf tool_exec_async_test")) done)))))
      (should (string-search "tool_exec_async_test" result))
      (should (string-search "exit 0" result)))))

(ert-deftest kargu-bash-output-is-capped-test ()
  "Foreground and background native jobs retain a bounded recent tail."
  (kargu-bash-test--with-core
    (let* ((kargu-process-max-bytes 256)
           (command "i=0; while [ $i -lt 300 ]; do echo xxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo completed")
           (result (kargu-test-await (lambda (done) (kargu-bash-run command nil nil done)))))
      (should (string-search "exit 0" result))
      (should (string-search "completed" result))
      (should (string-search "output truncated" result))
      (should-not kargu-bash--active-async-proc)
      (let* ((receipt (kargu-test-await (lambda (done) (kargu-bash-run command nil t done))))
             (job (gethash "p2" kargu-bash--processes)))
        (should (string-search "ID=[p2]" receipt))
        (kargu-bridge-test--wait (lambda () (eq (kargu-bash--job-state job) :done)))
        (should (= (plist-get (kargu-bash--job-result job) :code) 0))
        (with-current-buffer (kargu-bash--job-buffer job)
          (should (string-search "completed" (buffer-string)))
          (should (<= (string-bytes (buffer-string)) 256)))))))

(ert-deftest kargu-bash-job-is-live-bounded-and-cancellable-test ()
  "A live native job is visible and cancellation waits for process-group drain."
  (kargu-bash-test--with-core
    (let ((kargu-bash-timeout nil) (kargu-process-timeout 0.01)
          (kargu-process-max-bytes 256) result)
      (kargu-bash-run "echo started; sleep 30" nil nil (lambda (text) (setq result text)))
      (let ((job (kargu-bash-test--job)))
        (kargu-bridge-test--wait
         (lambda () (string-search "started" (kargu-bash-manage-job (concat "status " (kargu-bash--job-id job))))))
        (should-not result)
        (should (eq (kargu-bash--job-state job) :running))
        (let ((pid (kargu-bridge-job-pid (kargu-bash--job-handle job))))
          (kargu-bash-cancel-process (kargu-bash--job-id job))
          (should (eq (kargu-bash--job-state job) :cancelling))
          (kargu-bridge-test--wait (lambda () result))
          (should-not (file-exists-p (format "/proc/%s" pid)))
          (should (eq (kargu-bash--job-state job) :cancelled)))))))

(ert-deftest kargu-bash-kill-active-async-test ()
  "Stopping foreground work cannot borrow another project's UI handle."
  (kargu-bash-test--with-core
    (let (result)
      (kargu-bash-run "sleep 30" nil nil (lambda (text) (setq result text)))
      (kargu-bridge-test--wait (lambda () kargu-bash--active-async-proc))
      (should (kargu-bridge-job-p kargu-bash--active-async-proc))
      (kargu-bash-kill-active-async)
      (should-not kargu-bash--active-async-proc)
      (kargu-bridge-test--wait (lambda () result)))))

(ert-deftest kargu-bash-native-always-asks-despite-legacy-optout-test ()
  "Legacy confirm-bash=nil cannot silently grant arbitrary native execution."
  (kargu-bash-test--with-core
    (let ((kargu-permission-confirm-bash nil) result)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (when (eq (kargu-confirmation-operation request) :prompt)
                     (funcall (plist-get (kargu-confirmation-options request) :on-decision) :reject)))))
        (setq result (kargu-test-await (lambda (done) (kargu-bash-run "printf bad > effect" nil nil done)))))
      (should (string-search "ERROR:" result))
      (should-not (file-exists-p (expand-file-name "effect" root))))))

(ert-deftest kargu-bash-background-process-test ()
  "Native background receipts support cached list/status and scoped cancellation."
  (kargu-bash-test--with-core
    (let* ((receipt (kargu-test-await (lambda (done) (kargu-bash-run "sleep 30" nil t done))))
           (job (kargu-bash-test--job))
           (id (kargu-bash--job-id job)))
      (should (string-search (concat "ID=[" id "]") receipt))
      (should (string-search id (kargu-bash-run "list")))
      (should (string-search "RUNNING" (kargu-bash-run (concat "status " id))))
      (should (string-search "cancellation requested" (kargu-bash-run (concat "kill " id))))
      (should (eq (kargu-bash--job-state job) :cancelling))
      (kargu-bridge-test--wait (lambda () (eq (kargu-bash--job-state job) :cancelled)))
      (should (string-search "CANCELLED" (kargu-bash-run (concat "status " id)))))))

(ert-deftest kargu-permission-detailed-bash-rejection-test ()
  "Native rejection retains command, project and no-retry guidance."
  (kargu-bash-test--with-core
    (cl-letf (((symbol-function 'kargu-present-confirmation)
               (lambda (request)
                 (when (eq (kargu-confirmation-operation request) :prompt)
                   (funcall (plist-get (kargu-confirmation-options request) :on-decision) :reject)))))
      (let ((result (kargu-test-await (lambda (done) (kargu-bash-run "printf rejected_fixture" nil nil done)))))
        (should (string-search "Rejected command:" result))
        (should (string-search "rejected_fixture" result))
        (should (string-search "Allowed project root:" result))
        (should (string-search "Guidance:" result))))))

(ert-deftest kargu-bash-native-delayed-environment-change-rejects-test ()
  "Changed editor environment invalidates a pending exact command approval."
  (kargu-bash-test--with-core
    (let ((process-environment (copy-sequence process-environment)) decision result)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (when (eq (kargu-confirmation-operation request) :prompt)
                     (setq decision (plist-get (kargu-confirmation-options request) :on-decision))))))
        (kargu-bash-run "printf bad > effect" nil nil (lambda (text) (setq result text)))
        (kargu-bridge-test--wait (lambda () decision))
        (push "KARGU_CHANGED_AFTER_REVIEW=yes" process-environment)
        (funcall decision :approve)
        (kargu-bridge-test--wait (lambda () result))
        (should (string-search "ERROR:" result))
        (should-not (file-exists-p (expand-file-name "effect" root)))))))

(ert-deftest kargu-bash-native-mode-cycle-invalidates-old-approval-test ()
  "Returning to Agent mode cannot revive an approval from an earlier mode revision."
  (kargu-bash-test--with-core
    (let (decision result)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (when (eq (kargu-confirmation-operation request) :prompt)
                     (setq decision (plist-get (kargu-confirmation-options request) :on-decision))))))
        (kargu-bash-run "printf bad > effect" nil nil (lambda (text) (setq result text)))
        (kargu-bridge-test--wait (lambda () decision))
        (kargu-test-mode 'ask)
        (kargu-test-mode 'agent)
        (funcall decision :approve)
        (kargu-bridge-test--wait (lambda () result))
        (should (string-search "ERROR:" result))
        (should-not (file-exists-p (expand-file-name "effect" root)))))))

(ert-deftest kargu-bash-native-zero-output-and-explicit-timeout-test ()
  "Zero retention and a Bash-specific timeout preserve the completion channel."
  (kargu-bash-test--with-core
    (let* ((kargu-process-max-bytes 0)
           (result (kargu-test-await (lambda (done) (kargu-bash-run "printf discarded" nil nil done)))))
      (should (string-search "exit 0" result))
      (should-not (string-search "discarded" (with-current-buffer (kargu-bash--job-buffer (kargu-bash-test--job)) (buffer-string)))))
    (let* ((kargu-bash-timeout 0.2)
           (result (kargu-test-await (lambda (done) (kargu-bash-run "sleep 30" nil nil done)))))
      (should (string-search "bash timed out" result)))))

(ert-deftest kargu-bash-native-start-needs-callback-and-agent-mode-test ()
  "No synchronous bridge or hardcoded Agent mode bypass is available."
  (kargu-bash-test--with-core
    (should-error (kargu-bash-run "printf never" nil t))
    (kargu-test-mode 'ask)
    (should-error (kargu-bash-run "printf never" nil nil #'ignore))
    (should (= 0 (hash-table-count kargu-bash--processes)))))

(provide 'tests/test-native-bash)
;;; test-native-bash.el ends here
