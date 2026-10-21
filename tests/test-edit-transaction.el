;;; test-edit-transaction.el --- Edit publication boundary regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise real edit adapters with local files and controlled failures.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)
(require 'kargu/loop/heal)
(require 'tests/test-lsp-settle)

(ert-deftest kargu-edit-baseline-requires-current-reports-test ()
  "A configured checker or a failed snapshot cannot certify a baseline."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let* ((path (expand-file-name "a.txt" repo))
           (buffer (find-file-noselect path)))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-lsp-current-diagnostics-p)
                     (lambda (_) nil))
                    ((symbol-function 'kargu-lsp-diagnostics-snapshot)
                     (lambda (_) nil)))
            (should-not (plist-get (kargu-diff--capture-baseline-diagnostics path)
                                   :available))
            (cl-letf (((symbol-function 'kargu-lsp-current-diagnostics-p)
                       (lambda (_) t))
                      ((symbol-function 'kargu-lsp-diagnostics-snapshot)
                       (lambda (_) (error "Synthetic snapshot failure"))))
              (should-not (plist-get (kargu-diff--capture-baseline-diagnostics path)
                                     :available))))
        (kill-buffer buffer)))))

(ert-deftest kargu-edit-incomplete-batch-cannot-claim-no-regression-test ()
  "One known baseline does not certify an unavailable peer document."
  (let* ((sections '((:errors 1 :new-errors 0 :pre-existing-errors 1
                             :baseline-available t)
                    (:errors 0 :new-errors 0 :unavailable t)))
         (footer (kargu--loop-verify-footer sections 1 0)))
    (should (string-search "Verification incomplete" footer))
    (should-not (string-search "No new regressions" footer))))

(ert-deftest kargu-edit-failed-batch-does-not-report-deferred-success-test ()
  "A conflict on one target cancels every still-deferred peer."
  (let* ((table (make-hash-table :test #'equal))
         (batch (kargu-diff--make-patch-batch
                 :outcomes table :order '("a" "b") :pending 0 :state :waiting)))
    (puthash "a" '(:file "a" :status :applied-full :deferred t
                        :pre-state (:path "a")) table)
    (puthash "b" '(:file "b" :status :applied-full :deferred t
                        :pre-state (:path "b")) table)
    (cl-letf (((symbol-function 'kargu-diff--validate-pre-state)
               (lambda (_) (error "Synthetic revision conflict"))))
      (kargu-diff--finish-patch batch))
    (should-not (seq-some (lambda (outcome)
                           (eq (plist-get outcome :status) :applied-full))
                         (hash-table-values table)))))

(ert-deftest kargu-edit-isolated-workspace-refuses-escape-test ()
  "Disabling project policy never lets patch staging escape its scratch root."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let ((kargu-permission-strict-mode nil))
      (should-error
       (kargu-diff--parse-header-pair "--- a/../outside.txt"
                                      "+++ b/../outside.txt")))))

(ert-deftest kargu-edit-symbol-response-keeps-request-revision-test ()
  "A response for an earlier document version cannot acquire a fresh tick."
  (kargu-test-with-git-repo '(("a.txt" . "symbol\n"))
    (let* ((path (expand-file-name "a.txt" repo))
           (buffer (find-file-noselect path)) reply result)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-lsp--buffer-managed-p) (lambda (_) t))
                    ((symbol-function 'kargu-lsp--cached-file-symbols) (lambda (_) nil))
                    ((symbol-function 'eglot-current-server) (lambda () :server))
                    ((symbol-function 'kargu-lsp--buffer-uri) (lambda (_) "file:///a"))
                    ((symbol-function 'kargu-lsp--request)
                     (lambda (_method _params callback &optional _buffer)
                       (setq reply callback))))
            (kargu-lsp-get-file-symbols path
                                       (lambda (symbols error) (setq result (list symbols error))))
            (with-current-buffer buffer (goto-char (point-min)) (insert "changed "))
            (funcall reply '((:name "symbol" :kind 12
                                   :range (:start (:line 0 :character 0)
                                                  :end (:line 0 :character 6)))) nil)
            (should-not (car result))
            (should (stringp (cadr result))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-edit-failed-save-restores-written-disk-test ()
  "A save that writes and then fails restores the pre-edit bytes."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let* ((path (expand-file-name "a.txt" repo))
           (buffer (find-file-noselect path))
           (kargu-diff-review-mode 'auto)
           (kargu-diff-auto-save t))
      (unwind-protect
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _)
                       (write-region (point-min) (point-max) buffer-file-name nil 'silent)
                       (error "Synthetic failure after write"))))
            (should-error (kargu-diff-apply-proposal path "new\n"))
            (with-temp-buffer
              (insert-file-contents path)
              (should (equal (buffer-string) "old\n"))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-edit-single-step-rollback-keeps-earlier-snapshot-live-test ()
  "Rolling back the latest edit keeps the earlier step revision usable."
  (kargu-test-with-git-repo '(("a.txt" . "original\n"))
    (let ((path (expand-file-name "a.txt" repo))
          (kargu-diff-review-mode 'auto))
      (unwind-protect
          (progn
            (kargu-diff-apply-proposal path "first\n")
            (kargu-diff-apply-proposal path "second\n")
            (kargu-diff-rollback path t)
            (kargu-diff-rollback path t)
            (with-temp-buffer
              (insert-file-contents path)
              (should (equal (buffer-string) "original\n"))))
        (when-let* ((buffer (find-buffer-visiting path))) (kill-buffer buffer))))))

(ert-deftest kargu-edit-failed-observer-cannot-reverse-commit-test ()
  "A passive observer failure cannot undo a recorded successful write."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let ((path (expand-file-name "a.txt" repo))
          (kargu-diff-review-mode 'auto)
          (kargu-diff-after-apply-hook
           (list (lambda () (error "Synthetic observer failure")))))
      (unwind-protect
          (progn
            (should (eq (plist-get (kargu-diff-apply-proposal path "new\n") :status)
                        :applied-full))
            (with-temp-buffer
              (insert-file-contents path)
              (should (equal (buffer-string) "new\n")))
            (should (gethash path kargu-diff--snapshots)))
        (when-let* ((buffer (find-buffer-visiting path))) (kill-buffer buffer))))))

(ert-deftest kargu-edit-current-baseline-requires-real-generation-test ()
  "Only reports from the live Flymake generation establish a baseline."
  (let (report)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq report callback)))
      (flymake-start)
      (should-not (kargu-lsp-current-diagnostics-p buffer))
      (funcall report nil)
      (should (kargu-lsp-current-diagnostics-p buffer))
      (goto-char (point-max))
      (insert "; newer source\n")
      (should-not (kargu-lsp-current-diagnostics-p buffer)))))

(ert-deftest kargu-edit-retired-review-owner-cannot-write-test ()
  "Replacing the originating session invalidates its prepared edit."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let* ((path (expand-file-name "a.txt" repo))
           (state (kargu-diff--capture-pre-state path))
           (kargu-session--context (kargu-test-session-with-history)))
      (should-error (kargu-diff--commit-file-content state "new\n"))
      (with-temp-buffer
        (insert-file-contents path)
        (should (equal (buffer-string) "old\n"))))))

(ert-deftest kargu-edit-missing-baseline-is-unknown-not-new-test ()
  "An observed error without baseline evidence does not become a new error."
  (let ((delta (kargu--loop-compare-diagnostics nil "/tmp/unused" 1 nil "[error]")))
    (should (= (plist-get delta :new-errors) 0))
    (should (= (plist-get delta :unclassified-errors) 1))))

(ert-deftest kargu-edit-patch-limit-precedes-parser-and-filesystem-test ()
  "Oversized Unicode input is rejected before parsing or staging."
  (let ((kargu-diff-max-patch-bytes 3) parsed)
    (cl-letf (((symbol-function 'kargu-diff--parse-unified-patch)
               (lambda (_) (setq parsed t))))
      (should-error (kargu-diff-apply-patch "🙂"))
      (should-not parsed))))

(ert-deftest kargu-edit-failed-save-preserves-foreign-disk-test ()
  "A failed save cannot recover over unrelated external disk content."
  (kargu-test-with-git-repo '(("a.txt" . "old\n"))
    (let* ((path (expand-file-name "a.txt" repo))
           (buffer (find-file-noselect path))
           (kargu-diff-review-mode 'auto))
      (unwind-protect
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _)
                       (with-temp-buffer (write-region "foreign\n" nil path nil 'silent))
                       (error "Synthetic write conflict"))))
            (should-error (kargu-diff-apply-proposal path "new\n"))
            (with-temp-buffer
              (insert-file-contents path)
              (should (equal (buffer-string) "foreign\n"))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(provide 'tests/test-edit-transaction)
;;; test-edit-transaction.el ends here
