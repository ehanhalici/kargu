;;; test-lsp-settle.el --- Diagnostic freshness and ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real Flymake report functions run without servers or wall-clock sleeps.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defmacro kargu-lsp-test--with-checkers (backends &rest body)
  "Run BODY with BACKENDS in a temporary file and controllable timers.
Bind `buffer', `path', `poll', `deadline' and `results' for each case."
  (declare (indent 1))
  `(kargu-test-with-git-repo '(("main.el" . "(message \"test\")\n"))
     (let* ((path (expand-file-name "main.el" repo))
            (buffer (find-file-noselect path))
            (flymake-start-on-flymake-mode nil)
            (flymake-no-changes-timeout nil)
            (warning-minimum-level :emergency)
            (warning-minimum-log-level :emergency)
            poll deadline results)
       (ignore poll deadline results)
       (unwind-protect
           (with-current-buffer buffer
             (setq-local flymake-diagnostic-functions ,backends)
             (flymake-mode 1)
             (cl-letf (((symbol-function 'trusted-content-p) (lambda () t))
                       ((symbol-function 'run-at-time)
                        (lambda (_seconds repeat function &rest args)
                          (cond
                           (repeat (setq poll (lambda () (apply function args))))
                           ((eq function #'kargu-async-finish)
                            (setq deadline (lambda () (apply function args)))))
                          (timer-create))))
               ,@body))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (set-buffer-modified-p nil)
             (flymake-mode -1))
           (kill-buffer buffer))))))

(defun kargu-lsp-test--start-wait (path results-callback)
  "Start PATH verification, delivering arguments to RESULTS-CALLBACK."
  (kargu-lsp-wait-diagnostics path results-callback 2))

(ert-deftest kargu-lsp-settle-version-capability-preserves-input-test ()
  "Version support composes with existing capabilities without mutation."
  (let* ((input '(:textDocument (:publishDiagnostics (:relatedInformation t))))
         (before (copy-tree input))
         (output (kargu-lsp--diagnostic-capabilities input)))
    (should (equal input before))
    (should (eq (plist-get (plist-get (plist-get output :textDocument)
                                     :publishDiagnostics) :versionSupport) t)))
  (cl-letf (((symbol-function 'eglot--trampish-p) (lambda (_) nil)))
    (should (eq (plist-get (plist-get (plist-get (eglot-client-capabilities nil)
                                                :textDocument)
                                     :publishDiagnostics) :versionSupport) t))))

(ert-deftest kargu-lsp-settle-requires-new-report-not-stable-cache-test ()
  "An unchanged empty snapshot is not a completed checker run."
  (let (report)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq report callback)))
      (let ((task (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))))
        (funcall poll)
        (funcall poll)
        (should-not results)
        (funcall report nil)
        ;; Flymake keeps the backend's run token even after it reported.
        (should (flymake-is-running))
        (funcall poll)
        (funcall poll)
        (should (= (length results) 1))
        (should (string-search "no diagnostics (clean)" (cadar results)))
        (should-not (nth 2 (car results)))
        (should-not (kargu-async-task-timer task))
        (should-not (memq task kargu-async--pending))))))

(ert-deftest kargu-lsp-settle-waits-for-every-backend-test ()
  "One backend's empty report cannot stand in for another pending check."
  (let (first second)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq first callback))
              (lambda (callback &rest _) (setq second callback)))
      (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
      (funcall first nil)
      (funcall poll)
      (should-not results)
      (funcall second nil)
      (funcall poll)
      (should (= (length results) 1)))))

(ert-deftest kargu-lsp-settle-preserves-point-narrowing-and-match-data-test ()
  "Starting and completing verification preserves the source editor state."
  (let (report)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq report callback)))
      (narrow-to-region 2 8)
      (goto-char 4)
      (string-match "kept" "kept data")
      (let ((match (match-data)))
        (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
        (funcall report nil)
        (funcall poll)
        (should (= (point) 4))
        (should (= (point-min) 2))
        (should (= (point-max) 8))
        (should (equal (match-data) match))
        (should (= (length results) 1))))))

(ert-deftest kargu-lsp-settle-rejects-obsolete-report-functions-test ()
  "An old Flymake token cannot certify a newly requested verification."
  (let (reports)
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (push callback reports)))
      (flymake-start)
      (let ((old (car reports)))
        (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
        (should-error (funcall old nil))
        (funcall poll)
        (should-not results)
        (funcall (car reports) nil)
        (funcall old nil :force t)
        (funcall poll)
        (should-not results)
        (funcall (car reports) nil)
        (funcall poll)
        (should (= (length results) 1))))))

(ert-deftest kargu-lsp-settle-invalidated-document-is-unavailable-test ()
  "Edits and resource or checker replacement cannot yield a clean old result."
  (dolist (change '(edit rename close backend))
    (let (report)
      (kargu-lsp-test--with-checkers
          (list (lambda (callback &rest _) (setq report callback)))
        (let ((task (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))))
          (pcase change
            ('edit (goto-char (point-max)) (insert "changed"))
            ('rename (setq buffer-file-name (expand-file-name "renamed.el" repo)))
            ('close (kill-buffer buffer))
            ('backend (setq-local flymake-diagnostic-functions (list #'ignore))))
          (funcall report nil)
          (funcall poll)
          (funcall poll)
          (should (equal results (list (list path nil nil))))
          (should-not (kargu-async-task-timer task)))))))

(ert-deftest kargu-lsp-settle-pins-origin-project-test ()
  "Polling from elsewhere preserves the origin; reassignment invalidates it."
  (dolist (reassigned '(nil t))
    (let (report)
      (kargu-lsp-test--with-checkers
          (list (lambda (callback &rest _) (setq report callback)))
        (cl-letf (((symbol-function 'kargu-permission-project-root)
                   (lambda (&optional _) default-directory)))
          (setq default-directory repo)
          (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
          (funcall report nil)
          (when reassigned (setq default-directory "/tmp/kargu-other/"))
          (with-temp-buffer
            (setq default-directory "/tmp/kargu-foreign/")
            (funcall poll))
          (should (= (length results) 1))
          (if reassigned
              (should (equal (car results) (list path nil nil)))
            (should (string-search "clean" (cadar results)))))))))

(ert-deftest kargu-lsp-settle-stop-cancels-poll-and-late-report-test ()
  "Stopping the run closes the wait without consuming a late report."
  (let (report (kargu--loop-run (list :state 'tool)))
    (kargu-lsp-test--with-checkers
        (list (lambda (callback &rest _) (setq report callback)))
      (let ((task (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))))
        (kargu-async-cancel-owner kargu--loop-run)
        (funcall report nil)
        (funcall poll)
        (funcall deadline)
        (should-not results)
        (should (eq (kargu-async-task-state task) :cancelled))
        (should-not (kargu-async-task-timer task))
        (should-not (memq task kargu-async--pending))))))

(ert-deftest kargu-lsp-settle-stop-releases-real-timers-test ()
  "Run cancellation removes both actual scheduler registrations."
  (let ((schedule (symbol-function 'run-at-time))
        (kargu--loop-run (list :state 'tool)))
    (kargu-lsp-test--with-checkers (list (lambda (&rest _)))
      (cl-letf (((symbol-function 'run-at-time) schedule))
        (let* ((before (copy-sequence timer-list))
               (task (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results))))
               (owned (seq-difference timer-list before)))
          (should (= (length owned) 2))
          (kargu-async-cancel-owner kargu--loop-run)
          (should (eq (kargu-async-task-state task) :cancelled))
          (should-not (seq-intersection owned timer-list))
          (should-not results))))))

(ert-deftest kargu-lsp-settle-replaced-owner-releases-wait-test ()
  "An obsolete run cannot leave its repeating probe registered."
  (let ((kargu--loop-run (list :state 'tool)))
    (kargu-lsp-test--with-checkers (list (lambda (&rest _)))
      (let ((task (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))))
        (setq kargu--loop-run (list :state 'tool))
        (funcall poll)
        (should-not results)
        (should (eq (kargu-async-task-state task) :cancelled))
        (should-not (kargu-async-task-timer task))
        (should-not (memq task kargu-async--pending))))))

(ert-deftest kargu-lsp-settle-timeout-and-disabled-backends-not-clean-test ()
  "A missing report or failed backend never becomes an empty clean report."
  (dolist (failure '(timeout disabled))
    (let (report)
      (kargu-lsp-test--with-checkers
          (list (lambda (callback &rest _) (setq report callback)))
        (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
        (if (eq failure 'timeout)
            (funcall deadline)
          (funcall report :panic :explanation "Checker failed")
          (funcall poll))
        (funcall poll)
        (should (equal results (list (list path nil (eq failure 'timeout)))))))))

(ert-deftest kargu-lsp-settle-eglot-needs-matching-published-version-test ()
  "Eglot's initial cache replay is not proof for a new document version."
  (kargu-lsp-test--with-checkers (list #'eglot-flymake-backend)
    (let ((server 'server)
          (uri (eglot-path-to-uri path)))
      (setq-local eglot--managed-mode t
                  eglot--versioned-identifier 7
                  eglot--TextDocumentIdentifier-cache (cons (file-truename path) (list :uri uri))
                  eglot--diagnostics
                  (list (flymake-make-diagnostic buffer 1 2 :error "old error")))
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                ((symbol-function 'eglot-uri-to-path) (lambda (_) path))
                ((symbol-function 'eglot--managed-buffers) (lambda (_) (list buffer)))
                ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore))
        (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
        (should (flymake-diagnostics))
        (dolist (version '(nil 6))
          (eglot-handle-notification server 'textDocument/publishDiagnostics
                                     :uri uri :version version :diagnostics [])
          (funcall poll)
          (should-not results))
        (eglot-handle-notification server 'textDocument/publishDiagnostics
                                   :uri uri :version 7 :diagnostics [])
        ;; Manual Flymake still contains the old cache until the owned poll.
        (should (flymake-diagnostics))
        (funcall poll)
        (funcall poll)
        (should (= (length results) 1))
        (should (string-search "no diagnostics (clean)" (cadar results)))
        (should-not (flymake-diagnostics))))))

(ert-deftest kargu-lsp-settle-eglot-server-replacement-invalidates-test ()
  "A reply associated with a replacement server cannot satisfy the wait."
  (kargu-lsp-test--with-checkers (list #'eglot-flymake-backend)
    (let ((server 'initial))
      (setq-local eglot--managed-mode t eglot--versioned-identifier 1)
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore))
        (kargu-lsp-test--start-wait path (lambda (&rest args) (push args results)))
        (setq server 'replacement)
        (funcall poll)
        (should (equal results (list (list path nil nil))))))))

(provide 'tests/test-lsp-settle)
;;; test-lsp-settle.el ends here
