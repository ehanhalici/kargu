;;; test-resume-integration.el --- Interrupted package integration regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verify boundaries that independent package fixtures do not exercise.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu)
(require 'kargu/tools/execution)
(require 'kargu/tools/process/session)
(require 'tests/test-process-session)

(ert-deftest kargu-resume-old-claim-cannot-release-reused-run-name-test ()
  "An old claim cannot release a new claim even when run labels are reused."
  (let* ((app (kargu-application-create))
         (old (kargu-application-claim app :run-id "same")))
    (should (kargu-application-release app old))
    (let ((new (kargu-application-claim app :run-id "same")))
      (should-not (kargu-application-release app old))
      (should-not (kargu-application-release app (kargu-application-claim-token old)))
      (should-not (kargu-application-release app (kargu-application-claim-token new)))
      (should (eq new (kargu-application-active-claim-token app))))))

(ert-deftest kargu-resume-app-task-cannot-cross-claim-generation-test ()
  "An app-owned task does not acquire authority from a later run."
  (let* ((app (kargu-application-create))
         (old (kargu-application-claim app :run-id "old"))
         (task (kargu-async-start #'ignore :owner app)))
    (unwind-protect
        (progn
          (kargu-application-release app old)
          (kargu-application-claim app :run-id "old")
          (should-not (kargu-async-pending-p task)))
      (kargu-async-cancel task))))

(ert-deftest kargu-resume-sync-tool-does-not-bypass-approval-test ()
  "The no-callback public entry cannot invoke an executor before approval."
  (let ((kargu--tool-registry (kargu-tool-registry-create)) called)
    (kargu-test-mode 'agent)
    (kargu-register-tool
     "guarded" "Guarded" '(("type" . "object") ("properties" . :json-empty-object))
     (lambda (_args &optional _callback) (setq called t) "written")
     '(:needs-approval-p t))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_command _directory _risks callback)
                 (funcall callback nil))))
      (should (string-prefix-p "ERROR:" (kargu-execute-tool "guarded" nil)))
      (should-not called))))

(ert-deftest kargu-resume-drain-is-registry-local-test ()
  "Unloading a tool does not cancel a same-named tool in another registry."
  (let ((a (kargu-tool-registry-create)) (b (kargu-tool-registry-create))
        (context (kargu-tool-execution-context-create :root (kargu-test-scratch-root)))
        first second)
    (dolist (registry (list a b))
      (kargu-tool-registry-register
       registry :name "pending" :description "Pending"
       :parameters '(("type" . "object") ("properties" . :json-empty-object)) :executor (lambda (_args _done) nil)))
    (setq first (kargu-tool-gate-execute a context "pending" nil)
          second (kargu-tool-gate-execute b context "pending" nil))
    (unwind-protect
        (progn
          (kargu-tool-execution-drain a "pending" :cancel-p t)
          (should-not (kargu-async-pending-p first))
          (should (kargu-async-pending-p second)))
      (kargu-async-cancel first)
      (kargu-async-cancel second))))

(ert-deftest kargu-resume-delayed-approval-cannot-use-new-registry-test ()
  "Registry changes while approval is pending invalidate the prepared action."
  (let ((registry (kargu-tool-registry-create)) decision called task)
    (kargu-tool-registry-register
     registry :name "guarded" :description "Guarded"
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:needs-approval-p t)
     :executor (lambda (_args) (setq called t) "written"))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_command _directory _risks callback) (setq decision callback))))
      (setq task (kargu-tool-gate-execute
                  registry (kargu-tool-execution-context-create
                            :root (kargu-test-scratch-root)) "guarded" nil))
      (unwind-protect
          (progn
            (kargu-tool-registry-set-policy registry "guarded" '(:modes (ask)))
            (funcall decision t)
            (should-not called))
        (kargu-async-cancel task)))))

(ert-deftest kargu-resume-credential-wipe-does-not-mutate-config-test ()
  "Wiping a connection does not overwrite the caller's configuration key."
  (let* ((key (copy-sequence "synthetic-config-key"))
         (scope (kargu-credential-scope--create :raw-secret key)))
    (kargu-credential-scope-wipe scope)
    (should (equal key "synthetic-config-key"))))

(ert-deftest kargu-resume-edit-service-default-save-policy-test ()
  "The edit service constructor honors its documented auto-save default."
  (should (kargu-edit-service-auto-save (kargu-edit-service-create))))

(ert-deftest kargu-resume-explicit-nil-detaches-async-scope-test ()
  "Explicit nil owner and parent detach a task from dynamic legacy context."
  (let* ((kargu--loop-run (list :id "legacy"))
         (kargu-async--current-task (kargu-async-start #'ignore))
         (task (kargu-async-start #'ignore :owner nil :parent nil)))
    (unwind-protect
        (progn
          (should-not (kargu-async-task-owner task))
          (should-not (kargu-async-task-parent task)))
      (kargu-async-cancel kargu-async--current-task)
      (kargu-async-cancel task))))

(ert-deftest kargu-resume-credential-print-and-borrow-isolation-test ()
  "Printed records omit secrets and wiping a returned copy preserves ownership."
  (let* ((scope (kargu-credential-scope--create :raw-secret "synthetic-private-value"))
         (snapshot (kargu-connection-snapshot--create :credential-scope scope))
         (borrowed (kargu-credential-scope-secret scope)))
    (unwind-protect
        (progn
          (should-not (string-search "synthetic-private-value" (prin1-to-string snapshot)))
          (clear-string borrowed)
          (should (equal "synthetic-private-value" (kargu-credential-scope-secret scope))))
      (kargu-credential-scope-wipe scope))))

(ert-deftest kargu-resume-session-unicode-bound-and-narrowing-test ()
  "Interactive output preserves reader state and caps bytes, not characters."
  (with-temp-buffer
    (insert "reader text")
    (narrow-to-region 2 5)
    (goto-char 3)
    (let ((session (kargu-process-session--create :buffer (current-buffer)
                                                :max-bytes 7 :state :running)))
      (kargu-process-session--filter session "😀😀😀")
      ;; The old reader position was evicted; its marker collapses to start.
      (should (= (point) (point-min)))
      (should (= (kargu-process-session-bytes-read session) 12))
      (save-restriction
        (widen)
        (should (equal (buffer-string) "😀"))
        (should (<= (string-bytes (buffer-string)) 7))))))

(ert-deftest kargu-resume-session-natural-exit-releases-buffer-once-test ()
  "A natural exit releases its private buffer and delivers one terminal event."
  (kargu-session-test--with-core
    (let* ((calls 0)
           (session (kargu-session-test--start :on-exit (lambda (_code) (cl-incf calls)))))
      (kargu-process-session-close session)
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (kargu-process-session--finish session)
      (should (= calls 1))
      (should-not (buffer-live-p (kargu-process-session-buffer session))))))

(ert-deftest kargu-resume-session-spawn-error-releases-buffer-test ()
  "A failed interactive spawn does not retain its allocated output buffer."
  (kargu-session-test--with-core
    (let ((before (buffer-list)))
      (cl-letf (((symbol-function 'kargu-bridge-job-start)
                 (lambda (_connection _arguments callback &rest _options)
                   (funcall callback nil (kargu-bridge--fault "spawn_failed")))))
        (let ((session (kargu-process-session-start "cat" nil)))
          (push session kargu-session-test--sessions)
          (should (eq (kargu-process-session-state session) :closed))
          (should (kargu-process-session-failure session))))
      (should (equal before (buffer-list))))))

(ert-deftest kargu-resume-reaped-process-never-signaled-test ()
  "A late force-cancel never signals a numeric group after process reaping."
  (let ((process (make-pipe-process :name "kargu-reaped-regression" :noquery t)) signaled)
    (delete-process process)
    (process-put process 'kargu-pgid 12345)
    (cl-letf (((symbol-function 'signal-process)
               (lambda (&rest _args) (setq signaled t))))
      (kargu-process--force-cancel process)
      (should-not signaled))))

(ert-deftest kargu-resume-worker-source-policy-test ()
  "Encrypted, remote and unsupported auth sources never enter the worker."
  (dolist (source '("/tmp/secret.GPG" "/tmp/secret.asc" "/ssh:host:/authinfo"
                    "secrets:Login" (:source "secrets:Login") nil))
    (should-not (kargu-config-worker-source-path source))))

(ert-deftest kargu-resume-worker-empty-sources-never-spawns-test ()
  "An empty explicit auth source set cannot fall back to the child's defaults."
  (let ((auth-sources nil) result spawned)
    (let ((task (kargu-async-start (lambda (value _error) (setq result value)))))
      (unwind-protect
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest _args) (setq spawned t))))
            (kargu-config-worker-resolve "fixture" "fixture.invalid" task)
            (should (kargu-err-p result))
            (should-not spawned))
        (kargu-async-cancel task)))))

(ert-deftest kargu-resume-circuit-provider-switch-does-not-copy-state-test ()
  "Selecting another provider does not import the previous provider's breaker."
  (let ((kargu-circuit--registry (make-hash-table :test #'equal))
        (kargu-circuit--state :closed) (kargu-circuit--failure-count 0)
        (kargu-circuit-failure-threshold 1) (provider "first"))
    (cl-letf (((symbol-function 'kargu--provider-name) (lambda () provider)))
      (kargu-circuit-record-failure "Synthetic failure" "first")
      (setq provider "second")
      (should-not (kargu-circuit-open-p "second"))
      (should (kargu-circuit-open-p "first")))))

(ert-deftest kargu-resume-canonical-lsp-write-blocked-in-ask-test ()
  "Canonical LSP writes remain forbidden when a custom mutating list is empty."
  (let ((registry (kargu-tool-registry-create)) (kargu-loop-mutating-tools nil)
        called result)
    (kargu-tool-registry-register
     registry :name "edit_by_lsp" :description "LSP write"
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :executor (lambda (_args) (setq called t) "written"))
    (kargu-tool-gate-execute
     registry (kargu-tool-execution-context-create :mode 'ask) "edit_by_lsp" nil
     :callback (lambda (value) (setq result value)))
    (should (string-prefix-p "ERROR:" result))
    (should-not called)))

(ert-deftest kargu-resume-approved-environment-must-still-match-test ()
  "An old supplied approval cannot authorize a new process environment."
  (let* ((process-environment (cons "KARGU_FIXTURE=old" process-environment))
         (approval (kargu-tool-approval-create :tool-name "guarded")))
    (setcar process-environment "KARGU_FIXTURE=new")
    (should (kargu-err-p (kargu-tool-approval-claim approval :tool-name "guarded")))
    (should-not (kargu-tool-approval-claimed-p approval))))

(ert-deftest kargu-resume-draining-definition-cannot-be-replaced-test ()
  "A pending unload cannot later delete a replacement tool definition."
  (let ((registry (kargu-tool-registry-create))
        (schema '(("type" . "object") ("properties" . :json-empty-object))))
    (kargu-tool-registry-register registry :name "pending" :description "Pending"
                                  :parameters schema :executor #'ignore)
    (kargu-tool-registry-mark-draining registry "pending")
    (should-error
     (kargu-tool-registry-register registry :name "pending" :description "Replacement"
                                   :parameters schema :executor #'ignore))))

(ert-deftest kargu-resume-closed-edit-owner-does-not-fall-back-test ()
  "Explicitly closed edit contexts cannot acquire the default service."
  (let ((service (kargu-edit-service-create)))
    (kargu-edit-service-close service)
    (should-error (kargu-diff-with-service service (kargu-diff--current-service)))))

(ert-deftest kargu-resume-logical-request-retains-budget-and-circuit-test ()
  "A delayed retry retains the initial accounting owners across config changes."
  (let* ((first (kargu-budget-create)) (second (kargu-budget-create))
         (kargu-application--context (kargu-application-create :budget first))
         (provider "first"))
    (cl-letf (((symbol-function 'kargu--provider-name) (lambda () provider)))
      (kargu-http--ensure-logical-request 42)
      (setq provider "second")
      (kargu-application-set-budget second)
      (should (equal (kargu-http-request-scope 42) "first"))
      (should (eq (kargu-http-request-budget 42) first)))))

(ert-deftest kargu-resume-budget-refusal-is-handled-once-test ()
  "A body-level retry refusal must not fall through to a second callback."
  (let* ((budget (kargu-budget-create))
         (kargu-application--context (kargu-application-create :budget budget))
         (calls 0))
    (kargu-budget-seal budget)
    (should (kargu--api-schedule-retry
             "https://fixture.invalid" nil nil 42
             (lambda (_value) (cl-incf calls)) nil 0 "Synthetic failure"))
    (should (= calls 1))))

(ert-deftest kargu-resume-worker-preserves-credential-whitespace-test ()
  "The actual background worker parses its private JSON without trimming secrets."
  (let* ((path (make-temp-file "kargu-auth-fixture-"))
         (auth-sources (list path)) task result)
    (unwind-protect
        (progn
          (write-region "machine fixture.invalid login synthetic password \"  synthetic key  \"\n"
                        nil path nil 'silent)
          (setq task (kargu-async-start (lambda (value _error) (setq result value))))
          (kargu-config-worker-resolve "fixture" "fixture.invalid" task)
          (let ((deadline (+ (float-time) 3)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should (kargu-ok-p result))
          (should (equal (kargu-result-value result) "  synthetic key  ")))
      (when task (kargu-async-cancel task))
      (delete-file path))))




(ert-deftest kargu-resume-delayed-tool-cannot-cross-application-run-test ()
  "A pending tool invocation loses authority when its application run changes."
  (let* ((registry (kargu-tool-registry-create))
         (app (kargu-application-create))
         (claim (kargu-application-claim app :run-id "same"))
         decision called task)
    (kargu-tool-registry-register
     registry :name "guarded" :description "Guarded"
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:needs-approval-p t) :executor (lambda (_args) (setq called t)))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_command _directory _risks callback) (setq decision callback))))
      (setq task (kargu-tool-gate-execute
                  registry (kargu-tool-execution-context-create :app app) "guarded" nil))
      (unwind-protect
          (progn
            (kargu-application-release app claim)
            (kargu-application-claim app :run-id "same")
            (funcall decision t)
            (should-not called))
        (kargu-async-cancel task)))))

(ert-deftest kargu-resume-idle-project-cannot-cancel-foreign-job-test ()
  "Foreground cancellation cannot borrow another project's legacy process."
  (let* ((service (kargu-job-service--create))
         (kargu-bash--active-async-proc 'foreign) cancelled)
    (cl-letf (((symbol-function 'kargu-job-service-for-project) (lambda (&rest _) service))
              ((symbol-function 'kargu-bridge-job-cancel) (lambda (&rest _) (setq cancelled t))))
      (kargu-bash-kill-active-async)
      (should-not cancelled)
      (should (eq kargu-bash--active-async-proc 'foreign)))))

(ert-deftest kargu-resume-pruning-cannot-remove-foreign-job-with-same-id-test ()
  "Legacy aggregate pruning removes an ID only if it still names that exact job."
  (let* ((service (kargu-job-service--create :completed-limit 0))
         (kargu-bash-completed-jobs 0)
         (kargu-bash--processes (make-hash-table :test #'equal))
         (old (kargu-bash--make-job :id "p1" :state :done :started 1))
         (foreign (kargu-bash--make-job :id "p1" :state :running :started 2)))
    (puthash "p1" old (kargu-job-service-jobs service))
    (puthash "p1" foreign kargu-bash--processes)
    (kargu-bash--prune-jobs service)
    (should (eq foreign (gethash "p1" kargu-bash--processes)))))

(ert-deftest kargu-resume-job-service-close-cancels-only-owned-process-test ()
  "Closing one job service cancels its processes but leaves foreign jobs intact."
  (let* ((service (kargu-job-service--create))
         (kargu-job--services (make-hash-table :test #'equal))
         (kargu-bash--processes (make-hash-table :test #'equal))
         (own (kargu-bash--make-job :id "p1" :handle 'own :state :running))
         (foreign (kargu-bash--make-job :id "p2" :handle 'foreign :state :running)) killed)
    (puthash "p1" own (kargu-job-service-jobs service))
    (puthash "p2" foreign kargu-bash--processes)
    (cl-letf (((symbol-function 'kargu-bridge-job-cancel) #'ignore)
              ((symbol-function 'kargu-bridge-job-dispose) (lambda (handle) (push handle killed))))
      (kargu-job-service-close service)
      (kargu-job-service-close service))
    (should (equal killed '(own)))
    (should (eq foreign (gethash "p2" kargu-bash--processes)))))

(ert-deftest kargu-resume-async-patch-retains-edit-owner-test ()
  "A real asynchronous Git patch records its changes only in its captured service."
  (kargu-test-with-git-repo '(("sample.txt" . "old\n"))
    (let ((service (kargu-edit-service-create :root repo))
          (patch "--- a/sample.txt\n+++ b/sample.txt\n@@ -1 +1 @@\n-old\n+new\n") result)
      (kargu-test-mode 'agent)
      (unwind-protect
          (progn
            (kargu-diff-with-service service
              (kargu-diff-apply-patch patch (lambda (value) (setq result value))))
            (let ((deadline (+ (float-time) 3)))
              (while (and (not result) (< (float-time) deadline))
                (accept-process-output nil 0.01)))
            (should result)
            (should (gethash (expand-file-name "sample.txt" repo)
                             (kargu-edit-service-snapshots service))))
        (kargu-edit-service-close service)))))

(ert-deftest kargu-resume-edit-service-save-policy-is-effective-test ()
  "A service's explicit no-save policy overrides the compatibility global default."
  (kargu-test-with-git-repo '(("sample.txt" . "old\n"))
    (let ((service (kargu-edit-service-create :root repo :auto-save nil))
          (path (expand-file-name "sample.txt" repo)))
      (kargu-test-mode 'agent)
      (unwind-protect
          (progn
            (kargu-diff-with-service service (kargu-diff-apply-proposal path "new\n"))
            (with-temp-buffer (insert-file-contents path) (should (equal (buffer-string) "old\n"))))
        (when-let* ((buffer (find-buffer-visiting path)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (kargu-edit-service-close service)))))

(ert-deftest kargu-resume-legacy-text-is-not-typed-edit-success-test ()
  "A legacy display string does not prove applied or saved effects."
  (kargu-test-with-git-repo '(("sample.txt" . "old\n"))
    (let* ((path (expand-file-name "sample.txt" repo))
           (plan (kargu-edit-plan-create :path path :kind :write :proposed-content "new\n"))
           (outcome (kargu-edit--build-outcome plan path "Patch successfully applied")))
      (should (eq (kargu-edit-outcome-status outcome) :unknown))
      (should-not (kargu-edit-outcome-saved outcome)))))

(ert-deftest kargu-resume-worker-timeout-releases-owned-adapter-test ()
  "The worker entry bounds time even if its caller supplied no task timeout."
  (let* (result cleaned task
         (kargu-config-worker-runner-fn
         (lambda (_provider _host owned-task _timeout)
           (kargu-async-add-cleanup owned-task (lambda () (setq cleaned t))))))
    (setq task (kargu-async-start (lambda (value _error) (setq result value))))
    (unwind-protect
        (progn
          (kargu-config-worker-resolve "fixture" "fixture.invalid" task :timeout 0.01)
          (let ((deadline (+ (float-time) 1)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should (kargu-err-p result))
          (should cleaned))
      (kargu-async-cancel task))))

(provide 'tests/test-resume-integration)
;;; test-resume-integration.el ends here
