;;; test-heal.el --- Post-edit verification and self-healing tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verify post-edit reports and cancellation ownership without a server.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/loop)
(require 'kargu/loop/tools)
(require 'kargu/loop/heal)
(require 'kargu/tools/lsp)
(require 'tests/test-lsp-settle)

(defmacro kargu-heal-test--with-verification (diagnostics text timeout &rest body)
  "Verify one file whose diagnostics are DIAGNOSTICS and TEXT, then run BODY.
TIMEOUT determines whether the checker reports an incomplete verification.
The finished result and the run are bound to `result' and `run'."
  (declare (indent 3))
  `(let* ((run (list :state 'tool))
          (kargu--loop-run run)
          (kargu-diff--changed (make-hash-table :test #'equal))
          (result nil))
     (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                (lambda (file cb) (funcall cb file ,text ,timeout)))
               ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_p) ,diagnostics))
               ((symbol-function 'kargu--loop-add-result-and-continue)
                (lambda (_run _id _name text _queue) (setq result text))))
       (let ((path (expand-file-name "a.el" (kargu-permission-project-root))))
         (puthash path (list :baseline (list :available t :diagnostics nil))
                  kargu-diff--changed)
         (kargu--loop-verify-files run "id1" "edit_file" "edited ok" nil (list path)))
       ,@body)))

(ert-deftest kargu-heal-clean-file-passes-verification-test ()
  "No errors: the result says clean and no healing round is counted."
  (kargu-heal-test--with-verification nil "no problems" nil
    (should (string-search "Verification after edit (clean)" result))
    (should (string-search "Verification passed" result))
    (should-not (plist-get run :healing))))

(ert-deftest kargu-heal-errors-ask-for-a-fix-and-count-a-round-test ()
  "An error-severity diagnostic asks the model to fix it and counts the round."
  (kargu-heal-test--with-verification '((:severity 1) (:severity 2)) "boom" nil
    (should (string-search "1 error(s)" result))
    (should (string-search "SELF-HEALING (round 1 of" result))
    (should (= (plist-get run :healing) 1))))

(ert-deftest kargu-heal-timeout-is-not-reported-as-clean-test ()
  "A diagnostics timeout is stated, never passed off as a clean file."
  (kargu-heal-test--with-verification nil "partial" t
    (should (string-search "diagnostics timed out" result))
    (should (string-search "Verification incomplete" result))
    (should-not (string-search "Verification passed" result))))

(ert-deftest kargu-heal-no-checker-is-never-clean-test ()
  "Unavailable diagnostics have a distinct outcome, not a successful check."
  (kargu-heal-test--with-verification nil nil nil
    (should (string-search "Verification incomplete" result))
    (should-not (string-search "Verification passed" result))))

(ert-deftest kargu-heal-counts-error-markers-in-the-text-test ()
  "Without structured data, [error] markers in the text are counted."
  (cl-letf (((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_p) nil)))
    (should (= (kargu--loop-count-errors "/tmp/a.el" "[error] x\n[warn] y\n[error] z") 2))))

(ert-deftest kargu-heal-stopped-run-ignores-late-diagnostics-test ()
  "When the run was stopped, a late diagnostics callback does nothing."
  (let* ((run (list :state 'tool))
         (kargu--loop-run nil)
         (continued nil))
    (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
               (lambda (file cb) (funcall cb file "x" nil)))
              ((symbol-function 'kargu-diff-consume-file) #'ignore)
              ((symbol-function 'kargu-loop--set-state) #'ignore)
              ((symbol-function 'kargu--loop-add-result-and-continue)
               (lambda (&rest _) (setq continued t))))
      (kargu--loop-verify-files run "id1" "edit_file" "ok" nil '("/tmp/a.el"))
      (should-not continued))))

(defmacro kargu-heal-test--with-pending-changes (&rest body)
  "Run BODY with two pending edit records and controlled callbacks."
  (declare (indent 0))
  `(kargu-test-with-git-repo '(("a.el" . "first\n") ("b.el" . "second\n"))
     (let* ((first (expand-file-name "a.el" repo)) (second (expand-file-name "b.el" repo))
            (kargu-diff--changed (make-hash-table :test #'equal))
            (kargu-async--pending nil) (reports nil)
            (run (list :state 'tool :on-finish (lambda (report) (push report reports))))
            (kargu--loop-run run) (waiters nil) (continued nil))
       (ignore reports waiters continued)
       (puthash first (list :status :applied-full) kargu-diff--changed)
       (puthash second (list :status :applied-full) kargu-diff--changed)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                      (lambda (file callback) (push (cons file callback) waiters)))
                     ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_) nil))
                     ((symbol-function 'kargu-api-cancel) #'ignore)
                     ((symbol-function 'kargu-bash-kill-active-async) #'ignore)
                     ((symbol-function 'kargu--loop-add-result-and-continue)
                      (lambda (_run _id _name text _queue) (push text continued))))
             ,@body)
         (dolist (task (copy-sequence kargu-async--pending))
           (kargu-async-cancel-owner (kargu-async-task-owner task)))))))

(ert-deftest kargu-heal-change-identity-preserves-equal-newer-record-test ()
  "Even a structurally equal newer edit cannot be consumed by an old token."
  (kargu-heal-test--with-pending-changes
    (let* ((change (kargu-diff-pending-change first))
           (newer (copy-sequence (gethash first kargu-diff--changed))))
      (puthash first newer kargu-diff--changed)
      (should-not (kargu-diff-consume-change change))
      (should (eq newer (gethash first kargu-diff--changed)))
      (let ((current (kargu-diff-pending-change first)))
        (should (kargu-diff-consume-change current))
        (should-not (kargu-diff-consume-change current))))))

(ert-deftest kargu-heal-stop-consumes-whole-captured-batch-test ()
  "Stopping the real run clears both current and not-yet-visited old signals."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (let ((callback (cdar waiters)))
      (kargu-loop-stop "test cancellation")
      (funcall callback first "late" nil)
      (should-not (kargu-diff-changed-files))
      (should-not kargu-async--pending)
      (should-not continued)
      (should (eq (plist-get (car reports) :status) :stopped))
      (should-not (plist-get (kargu-loop--finish-report (list :state 'done) :done "next") :pending-files)))))

(ert-deftest kargu-heal-stop-preserves-new-edit-and-discards-old-reply-test ()
  "Cancellation and a late old callback cannot delete a replacement change."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (let ((callback (cdar waiters)) (newer (list :status :applied-full :at "new")))
      (puthash first newer kargu-diff--changed)
      (kargu-loop-stop)
      (funcall callback first "obsolete" nil)
      (should (eq newer (gethash first kargu-diff--changed)))
      (should-not (gethash second kargu-diff--changed))
      (should-not continued)
      (should-not kargu-async--pending))))

(ert-deftest kargu-heal-completion-consumes-only-original-records-test ()
  "A normal completion leaves any newly applied edit pending for its own check."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (let ((newer (list :status :applied-full :at "new")))
      (puthash first newer kargu-diff--changed)
      (funcall (cdar waiters) first "first checked" nil)
      (funcall (cdar waiters) second "second checked" nil)
      (should (eq newer (gethash first kargu-diff--changed)))
      (should-not (gethash second kargu-diff--changed))
      (should (= (length continued) 1))
      (should-not kargu-async--pending))))

(ert-deftest kargu-heal-duplicate-file-callback-cannot-repeat-next-wait-test ()
  "An old per-file continuation cannot start the next checker twice."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (let ((first-reply (cdar waiters)))
      (funcall first-reply first "first checked" nil)
      (funcall first-reply first "duplicate" nil)
      (should (= (length waiters) 2))
      (funcall (cdar waiters) second "second checked" nil)
      (funcall first-reply first "late" nil)
      (should (= (length continued) 1))
      (should-not (kargu-diff-changed-files))
      (should-not kargu-async--pending))))

(ert-deftest kargu-heal-startup-error-releases-owned-records-test ()
  "A synchronous checker setup failure is reported as unavailable and cleaned."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
               (lambda (&rest _) (error "Checker setup failed"))))
      (funcall (cdar waiters) first "first checked" nil))
    (should (= (length continued) 1))
    (should (string-search "Checker setup failed" (car continued)))
    (should (string-search "Verification incomplete" (car continued)))
    (should-not (string-search "Verification passed" (car continued)))
    (should-not (kargu-diff-changed-files))
    (should-not kargu-async--pending)))

(ert-deftest kargu-heal-cleanup-keeps-captured-path-after-project-switch-test ()
  "Cleanup never resolves an old relative path in a newly selected project."
  (kargu-heal-test--with-pending-changes
    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first second))
    (with-temp-buffer
      (setq-local kargu-permission--override-root temporary-file-directory)
      (kargu-async-cancel-owner run))
    (should-not (kargu-diff-changed-files))
    (should-not kargu-async--pending)
    (should-not continued)))

(ert-deftest kargu-heal-completion-closes-batch-before-next-work-test ()
  "Reentrant next work is not adopted or cancelled by the completed batch."
  (kargu-heal-test--with-pending-changes
    (let (next-task)
      (cl-letf (((symbol-function 'kargu--loop-add-result-and-continue)
                 (lambda (&rest _)
                   (puthash first (list :status :applied-full :at "next") kargu-diff--changed)
                   (setq next-task (kargu-async-start #'ignore)))))
        (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first))
        (funcall (cdar waiters) first "checked" nil)
        (should (kargu-async-pending-p next-task))
        (should-not (kargu-async-task-parent next-task))
        (should (gethash first kargu-diff--changed))))))

(ert-deftest kargu-heal-real-diagnostic-wait-cancels-with-batch-test ()
  "A real Flymake wait is a child and cannot publish after the run stops."
  (let (report continued)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq report callback)))
      (let* ((run (list :state 'tool)) (kargu--loop-run run)
             (kargu-diff--changed (make-hash-table :test #'equal))
             (kargu-async--pending nil))
        (puthash path (list :status :applied-full) kargu-diff--changed)
        (cl-letf (((symbol-function 'kargu-api-cancel) #'ignore)
                  ((symbol-function 'kargu-bash-kill-active-async) #'ignore)
                  ((symbol-function 'kargu--loop-add-result-and-continue)
                   (lambda (&rest _) (setq continued t))))
          (let ((task (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list path))))
            (should (= (length kargu-async--pending) 2))
            (should (seq-some (lambda (child) (eq (kargu-async-task-parent child) task))
                              kargu-async--pending))
            (kargu-loop-stop)
            (funcall report nil)
            (funcall poll)
            (should-not continued)
            (should-not kargu-async--pending)
            (should-not (kargu-diff-changed-files))))))))

(ert-deftest kargu-heal-compares-baseline-diagnostics-across-line-shifts-test ()
  "Pre-existing errors shifted in line numbers do not trigger self-healing,
whereas a genuinely new error (even when an old error was fixed) triggers healing."
  (kargu-test-with-git-repo '(("a.el" . "(defun a ()\n  (bad-call))\n"))
    (let* ((path (expand-file-name "a.el" repo))
           (run (list :state 'tool))
           (kargu--loop-run run)
           (kargu-diff--changed (make-hash-table :test #'equal))
           (result nil))
      ;; Case 1: Pre-existing error at line 2 shifts to line 10 after edit -> no new errors
      (puthash path
               (list :status :applied-full
                     :baseline (list :available t
                                     :diagnostics
                                     (list (list :file path :severity 1 :line 2 :character 2
                                                 :source "elisp" :message "Unbound: bad-call"))))
               kargu-diff--changed)
      (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                 (lambda (file cb) (funcall cb file "[error] L10:C2: Unbound: bad-call" nil)))
                ((symbol-function 'kargu-lsp--diagnostics-data)
                 (lambda (_p)
                   (list (list :file path :severity 1 :line 10 :character 2
                               :source "elisp" :message "Unbound: bad-call"))))
                ((symbol-function 'kargu--loop-add-result-and-continue)
                 (lambda (_run _id _name text _queue) (setq result text))))
        (kargu--loop-verify-files run "id1" "edit_file" "edited ok" nil (list path))
        (should (string-search "1 pre-existing error(s)" result))
        (should (string-search "No new regressions observed" result))
        (should-not (plist-get run :healing)))
      ;; Case 2: Old error resolved, but a different new error is introduced (same total count 1 -> 1)
      (setq result nil)
      (puthash path
               (list :status :applied-full
                     :baseline (list :available t
                                     :diagnostics
                                     (list (list :file path :severity 1 :line 2 :character 2
                                                 :source "elisp" :message "Unbound: old-error"))))
               kargu-diff--changed)
      (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                 (lambda (file cb) (funcall cb file "[error] L5:C0: Unbound: brand-new-error" nil)))
                ((symbol-function 'kargu-lsp--diagnostics-data)
                 (lambda (_p)
                   (list (list :file path :severity 1 :line 5 :character 0
                               :source "elisp" :message "Unbound: brand-new-error"))))
                ((symbol-function 'kargu--loop-add-result-and-continue)
                 (lambda (_run _id _name text _queue) (setq result text))))
        (kargu--loop-verify-files run "id2" "edit_file" "edited ok" nil (list path))
        (should (string-search "Baseline delta: 1 new, 0 pre-existing, 1 resolved error(s)" result))
        (should (string-search "SELF-HEALING (round 1 of" result))
        (should (= (plist-get run :healing) 1))))))

(ert-deftest kargu-heal-baseline-ticket-rejects-replaced-server-or-document-and-preserves-first-baseline-test ()
  "Replaced server/process/document or post-edit tick never produces '0 new error(s)',
and a second edit before consumption preserves the pre-first-edit baseline."
  (kargu-test-with-git-repo '(("a.el" . "(defun a ()\n  (bad-call))\n"))
    (let* ((path (expand-file-name "a.el" repo))
           (buf (find-file-noselect path))
           (proc-1 (make-pipe-process :name "kargu-heal-srv-1" :noquery t))
           (proc-2 (make-pipe-process :name "kargu-heal-srv-2" :noquery t))
           (server-1 (vector 'srv1))
           (server-2 (vector 'srv2))
           (curr-server server-1)
           (curr-proc proc-1)
           (curr-ver 1)
           (diags (list (list :file path :severity 1 :line 2 :character 2
                              :source "elisp" :message "Unbound: bad-call")))
           (kargu-diff-review-mode 'auto)
           (kargu-diff-auto-save t))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-lsp-current-diagnostics-p) (lambda (_) t))
                    ((symbol-function 'kargu-lsp-diagnostics-snapshot) (lambda (_) diags))
                    ((symbol-function 'kargu-lsp--diagnostic-backends) (lambda () '(elisp-flymake)))
                    ((symbol-function 'eglot-current-server)
                     (lambda () (and (bound-and-true-p eglot--managed-mode) curr-server)))
                    ((symbol-function 'jsonrpc--process) (lambda (_) curr-proc)))
            (with-current-buffer buf
              (setq-local eglot--managed-mode t
                          eglot--versioned-identifier curr-ver
                          flymake-mode t))
            (let ((captured (kargu-diff--capture-baseline-diagnostics path)))
              (should (plist-get captured :available))
              ;; Post-edit tick has not advanced yet -> cannot use current snapshot as pre-edit baseline
              (should-not (plist-get (kargu--loop-compare-diagnostics captured path 1 nil "[error]")
                                     :baseline-available))
              ;; Advance buffer tick & server version via real edit
              (kargu-diff-apply-replace path "(bad-call)" "(bad-call) ; edit 1")
              (with-current-buffer buf
                (setq curr-ver 2 eglot--versioned-identifier 2))
              ;; Second edit before consuming change preserves the pre-first-edit baseline
              (setq diags (list (list :file path :severity 1 :line 2 :character 2
                                      :source "elisp" :message "Unbound: introduced-by-edit-1")))
              (kargu-diff-apply-replace path "; edit 1" "; edit 2")
              (with-current-buffer buf
                (setq curr-ver 3 eglot--versioned-identifier 3))
              (let* ((change (kargu-diff-pending-change path))
                     (base (kargu-diff-change-baseline change)))
                (should (equal (plist-get (car (plist-get base :diagnostics)) :message)
                               "Unbound: bad-call"))
                ;; Compatible producer + advanced tick/version classifies introduced error as new
                (let ((delta (kargu--loop-compare-diagnostics base path 1 nil "[error]")))
                  (should (plist-get delta :baseline-available))
                  (should (= (plist-get delta :new-errors) 1))
                  (should (= (plist-get delta :resolved-errors) 1)))
                ;; Replaced Eglot server process invalidates baseline -> never claims 0 new errors
                (setq diags (list (list :file path :severity 1 :line 2 :character 2
                                        :source "elisp" :message "Unbound: bad-call")))
                (setq curr-proc proc-2)
                (let ((delta (kargu--loop-compare-diagnostics base path 1 nil "[error]")))
                  (should-not (plist-get delta :baseline-available))
                  (should (= (plist-get delta :unclassified-errors) 1)))
                ;; Replaced Eglot server instance invalidates baseline
                (setq curr-proc proc-1 curr-server server-2)
                (should-not (plist-get (kargu--loop-compare-diagnostics base path 1 nil "[error]")
                                       :baseline-available))
                ;; Recreated buffer for the same path invalidates baseline
                (setq curr-server server-1)
                (kill-buffer buf)
                (setq buf (find-file-noselect path))
                (with-current-buffer buf
                  (setq-local eglot--managed-mode t
                              eglot--versioned-identifier 4
                              flymake-mode t))
                (let* ((section (kargu--loop-diag-section path "[error] Unbound: bad-call" nil base))
                       (footer (kargu--loop-verify-footer (list section) 1 0)))
                  (should-not (plist-get section :baseline-available))
                  (should (string-search "Baseline comparison unavailable" footer))
                  (should-not (string-search "0 new error(s)" footer))))))
        (when (process-live-p proc-1) (delete-process proc-1))
        (when (process-live-p proc-2) (delete-process proc-2))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest kargu-heal-native-scheduler-exact-settlement-and-debt-preservation-test ()
  "Native changes consume only on exact terminal settlement; B is not consumed by A's
late diagnostic, and timeout/unavailable/error/stop/delete/closed/budget keep debt."
  (let ((doc-id "editor_document_11111111-1234-4234-8234-123456789abc")
        (consumed nil))
    (cl-letf (((symbol-function 'kargu-bridge-edit-history-consume)
               (lambda (_app &rest opts)
                 (push (plist-get opts :edit-id) consumed)
                 (funcall (plist-get opts :callback)
                          (let ((ht (make-hash-table :test #'equal)))
                            (puthash "consumed" t ht)
                            ht)
                          nil))))
      ;; 1. Timeout, unavailable, error, deleted, closed -> never consume native debt
      (dolist (case '(timeout unavailable error deleted closed stop budget))
        (setq consumed nil)
        (kargu-heal-test--with-pending-changes
          (let ((buf (find-file-noselect first)))
            (unwind-protect
                (let* ((tick (with-current-buffer buf
                               (setq-local kargu-bridge-edit-document--id (cons buf doc-id))
                               (buffer-chars-modified-tick)))
                       (id (append (list :native t :application 'app :lease 'lease
                                         :edit-id "edit-a" :edit-revision 1
                                         :file-index 0 :final-hash "hash-a"
                                         :document-id doc-id :document-tick tick)
                                   (pcase case
                                     ('deleted (list :deleted t :final-hash nil
                                                     :document-id nil :document-tick nil))
                                     ('closed (list :closed t
                                                    :document-id nil :document-tick nil))))))
                  (remhash second kargu-diff--changed)
                  (puthash first id kargu-diff--changed)
                  (if (eq case 'budget)
                      (let ((kargu-max-healing-steps 2))
                        (plist-put run :healing 2)
                        (kargu-loop--after-budget run "id" "edit_file" "applied" nil (list first)))
                    (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first))
                    (if (eq case 'stop)
                        (kargu-loop-stop "stop")
                      (pcase case
                        ('timeout (funcall (cdar waiters) first "No diagnostics" t))
                        ('unavailable (funcall (cdar waiters) first nil nil))
                        ('error (funcall (cdar waiters) first "[error] syntax error" nil))
                        (_ (funcall (cdar waiters) first "No diagnostics" nil)))))
                  (should-not consumed)
                  (should (eq id (gethash first kargu-diff--changed))))
              (when (buffer-live-p buf)
                (with-current-buffer buf (set-buffer-modified-p nil))
                (kill-buffer buf))))))
      ;; 2. Edit B on the same path before A's diagnostic settles -> B is never consumed by A
      (setq consumed nil)
      (kargu-heal-test--with-pending-changes
        (let ((buf (find-file-noselect first)))
          (unwind-protect
              (let* ((tick (with-current-buffer buf
                             (setq-local kargu-bridge-edit-document--id (cons buf doc-id))
                             (buffer-chars-modified-tick)))
                     (id-a (list :native t :application 'app :lease 'lease
                                 :edit-id "edit-a" :edit-revision 1
                                 :file-index 0 :final-hash "hash-a"
                                 :document-id doc-id :document-tick tick)))
                (remhash second kargu-diff--changed)
                (puthash first id-a kargu-diff--changed)
                (kargu--loop-verify-files run "id" "edit_file" "applied" nil (list first))
                (with-current-buffer buf
                  (insert ";; edit B\n")
                  (save-buffer))
                (let* ((tick-b (with-current-buffer buf (buffer-chars-modified-tick)))
                       (id-b (list :native t :application 'app :lease 'lease
                                   :edit-id "edit-b" :edit-revision 2
                                   :file-index 0 :final-hash "hash-b"
                                   :document-id doc-id :document-tick tick-b)))
                  (puthash first id-b kargu-diff--changed)
                  (funcall (cdar waiters) first "No diagnostics" nil)
                  (should-not consumed)
                  (should (eq id-b (gethash first kargu-diff--changed)))
                  (should (string-search "Verification incomplete" (car continued)))
                  ;; Now verify Edit B with its own fresh diagnostic at tick-b -> settles B
                  (setq waiters nil continued nil)
                  (kargu--loop-verify-files run "id-b" "edit_file" "applied-b" nil (list first))
                  (funcall (cdar waiters) first "No diagnostics" nil)
                  (should (equal consumed '("edit-b")))
                  (should-not (gethash first kargu-diff--changed))
                  (should (string-search "Verification passed" (car continued)))))
            (when (buffer-live-p buf)
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf))))))))

(ert-deftest kargu-heal-repeated-error-stops-healing-and-preserves-tool-queue-test ()
  "Repeating the same new error stops self-healing instead of looping; existing
tool queue continues uninterrupted, and cancelled heal never fabricates clean."
  (kargu-test-with-git-repo '(("a.el" . "(defun a ()\n  (bad-1))\n"))
    (let* ((path (expand-file-name "a.el" repo))
           (kargu-max-healing-steps 3)
           (run (list :state 'tool))
           (kargu--loop-run run)
           (kargu-diff--changed (make-hash-table :test #'equal))
           (diags (list (list :file path :severity 1 :line 2 :character 2
                              :source "elisp" :message "Unbound: bad-1")))
           (delivered nil))
      (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                 (lambda (file cb) (funcall cb file "[error] L2:C2: Unbound: bad-1" nil)))
                ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_p) diags))
                ((symbol-function 'kargu--loop-add-result-and-continue)
                 (lambda (_run id name text queue)
                   (push (list :id id :name name :text text :queue queue) delivered))))
        ;; Round 1: new error admitted -> SELF-HEALING (round 1 of 3), queue preserved
        (puthash path (list :status :applied-full
                            :baseline (list :available t :diagnostics nil))
                 kargu-diff--changed)
        (kargu--loop-verify-files run "call-1" "edit_file" "applied-1"
                                  '((("id" . "queued-call"))) (list path))
        (should (= (plist-get run :healing) 1))
        (should (equal (plist-get (car delivered) :queue) '((("id" . "queued-call")))))
        (should (string-search "SELF-HEALING (round 1 of 3)"
                               (plist-get (car delivered) :text)))
        ;; Round 2 with the exact same error -> immediately stops self-healing
        (puthash path (list :status :applied-full
                            :baseline (list :available t :diagnostics nil))
                 kargu-diff--changed)
        (kargu--loop-verify-files run "call-2" "edit_file" "applied-2"
                                  '((("id" . "queued-call-2"))) (list path))
        (should (= (plist-get run :healing) 3))
        (should (equal (plist-get (car delivered) :queue) '((("id" . "queued-call-2")))))
        (should (string-search "SELF-HEALING STOPPED: identical diagnostic error(s) repeated"
                               (plist-get (car delivered) :text)))
        ;; Next edit on the same run hits budget gate without fabricating clean verification
        (puthash path (list :native t :application 'app :lease 'lease
                            :edit-id "edit-3" :edit-revision 3
                            :file-index 0 :final-hash "hash-3")
                 kargu-diff--changed)
        (kargu--loop-after-tool run "call-3" "edit_file" "applied-3"
                                '((("id" . "queued-call-3"))))
        (should (string-search "SELF-HEALING BUDGET SPENT (3 of 3 error rounds used)"
                               (plist-get (car delivered) :text)))
        (should-not (string-search "Verification passed" (plist-get (car delivered) :text)))
        (should (equal (plist-get (car delivered) :queue) '((("id" . "queued-call-3")))))
        (should (gethash path kargu-diff--changed))))))

(provide 'tests/test-heal)
;;; test-heal.el ends here
