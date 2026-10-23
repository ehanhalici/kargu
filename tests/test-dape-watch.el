;;; test-dape-watch.el --- Debugger watch ownership tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise copied watch snapshots and delayed evaluation without a debugger.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defvar dape--watched)

(ert-deftest kargu-dape-watch-store-isolates-owner-identities-test ()
  "Watches require the same connection, workspace and chat session."
  (let ((kargu-dape--watches (make-hash-table :test #'eq :weakness 'key)))
    (with-temp-buffer
      (setq-local kargu--session-id "first")
      (should (equal (kargu-dape-watch-expressions 'local "first-value") '("first-value")))
      (should-not (kargu-dape-watch-expressions 'replacement))
      (setq-local kargu--session-id "second")
      (should-not (kargu-dape-watch-expressions 'local))
      (kargu-dape-watch-expressions 'local "second-value")
      (setq-local kargu--session-id "first")
      (should (equal (kargu-dape-watch-expressions 'local) '("first-value")))
      (let ((kargu-permission--override-root temporary-file-directory))
        (should-not (kargu-dape-watch-expressions 'local))
        (kargu-dape-watch-expressions 'local "foreign-value")
        (should (equal (kargu-dape-watch-expressions 'local) '("foreign-value"))))
      (should (equal (kargu-dape-watch-expressions 'local) '("first-value")))
      (should (eq (hash-table-weakness kargu-dape--watches) 'key)))))

(ert-deftest kargu-dape-watch-store-copies-and-deduplicates-test ()
  "Neither caller strings nor returned snapshots can mutate stored watches."
  (let ((kargu-dape--watches (make-hash-table :test #'eq :weakness 'key))
        (expression (copy-sequence "value")))
    (let ((snapshot (kargu-dape-watch-expressions 'local expression)))
      (aset expression 0 ?x)
      (aset (car snapshot) 0 ?y)
      (setcdr snapshot '("injected")))
    (should (equal (kargu-dape-watch-expressions 'local "value") '("value")))
    (should (equal (kargu-dape-watch-expressions 'local "other") '("other" "value")))
    (should (equal (kargu-dape-watch-expressions 'local "value" t) '("other")))
    (should (equal (kargu-dape-watch-expressions 'local "missing" t) '("other")))
    (should (equal (kargu-dape-watch-expressions 'local " \n ") '("other")))
    (should-error (kargu-dape-watch-expressions nil "value") :type 'user-error)
    (should-error (kargu-dape-watch-expressions 'local 1) :type 'user-error)))

(defmacro kargu-dape-test--with-watches (&rest body)
  "Run BODY with a fake paused connection and controllable watch replies."
  (declare (indent 0))
  `(with-temp-buffer
     (setq-local kargu--session-id "watch-session")
     (let ((thread (list :id 1 :status 'stopped))
           (kargu-dape--watches (make-hash-table :test #'eq :weakness 'key))
           (kargu-async--pending nil)
           (kargu--loop-run (list :state 'tools))
           (connection 'local) (deferred nil) (requests nil) (replies nil) (results nil))
       (ignore deferred requests replies results)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () connection))
                     ((symbol-function 'kargu-dape--raw-connection) (lambda () connection))
                     ((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) (list connection)))
                     ((symbol-function 'dape--threads) (lambda (_) (list thread)))
                     ((symbol-function 'dape--thread-id) (lambda (_) 1))
                     ((symbol-function 'dape--stack-id) (lambda (_) 1))
                     ((symbol-function 'dape--stack-trace)
                      (lambda (_conn work _limit callback)
                        (setf (plist-get work :stackFrames) (list (list :id 1)))
                        (funcall callback)))
                     ((symbol-function 'dape--current-stack-frame) (lambda (_) '(:id 1)))
                     ((symbol-function 'dape--evaluate-expression)
                      (lambda (conn _frame expression context callback)
                        (push (list conn expression context) requests)
                        (if deferred (push callback replies)
                          (funcall callback '(:result "42") nil)))))
             ,@body)
         (kargu-async-cancel-owner kargu--loop-run)))))

(ert-deftest kargu-dape-watch-never-reads-or-mutates-dape-ui-test ()
  "Native Dape watches and their UI hooks are untouched by Kargu operations."
  (kargu-dape-test--with-watches
    (let* ((native '((:name "foreign-secret")))
           (dape--watched native))
      (cl-letf (((symbol-function 'dape-watch-dwim)
                 (lambda (&rest _) (ert-fail "Global Dape watch mutation"))))
        (kargu-dape-watch "local-value" nil (lambda (text) (push text results)))
        (should (equal requests '((local "local-value" "watch"))))
        (should (string-search "local-value" (car results)))
        (should-not (string-search "foreign-secret" (car results)))
        (kargu-dape-watch "local-value" t (lambda (text) (push text results)))
        (should (string-search "WATCH LIST: 0" (car results)))
        (should (= (length requests) 1))
        (should (eq native dape--watched))
        (should (equal native '((:name "foreign-secret")))))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-watch-sequential-evaluation-uses-captured-origin-test ()
  "Unrelated current buffers cannot redirect a multi-expression watch request."
  (kargu-dape-test--with-watches
    (kargu-dape-watch-expressions connection "first")
    (kargu-dape-watch-expressions connection "second")
    (setq deferred t)
    (kargu-dape-watch nil nil (lambda (text) (push text results)))
    (should (= (length requests) 1))
    (with-temp-buffer
      (setq-local kargu--session-id "foreign")
      (setq-local kargu-permission--override-root temporary-file-directory)
      (funcall (pop replies) '(:result "2") nil)
      (should (= (length requests) 2))
      (let ((last (pop replies)))
        (funcall last '(:result "1") nil)
        (funcall last '(:result "duplicate") nil)))
    (should (= (length results) 1))
    (should (equal (reverse requests) '((local "second" "watch") (local "first" "watch"))))
    (should (string-search "WATCH LIST: 2" (car results)))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-watch-obsolete-replies-cannot-continue-test ()
  "Session, project and connection reassignment prevent another evaluation."
  (dolist (change '(session root connection))
    (kargu-dape-test--with-watches
      (kargu-dape-watch-expressions connection "first")
      (kargu-dape-watch-expressions connection "second")
      (setq deferred t)
      (kargu-dape-watch nil nil (lambda (text) (push text results)))
      (pcase change
        ('session (setq-local kargu--session-id "replacement"))
        ('root (setq-local kargu-permission--override-root temporary-file-directory))
        ('connection (setq connection 'replacement)))
      (let ((reply (pop replies)))
        (funcall reply '(:result "obsolete") nil)
        (funcall reply '(:result "duplicate") nil))
      (should (= (length requests) 1))
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-watch-cancellation-suppresses-late-evaluation-test ()
  "Stopping the owner cancels nested evaluation without a second expression."
  (kargu-dape-test--with-watches
    (kargu-dape-watch-expressions connection "first")
    (kargu-dape-watch-expressions connection "second")
    (setq deferred t)
    (kargu-dape-watch nil nil (lambda (text) (push text results)))
    (kargu-async-cancel-owner kargu--loop-run)
    (funcall (pop replies) '(:result "late") nil)
    (should (= (length requests) 1))
    (should-not results)
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-watch-refuses-without-paused-connection-test ()
  "An unavailable session cannot mutate any watch collection."
  (kargu-dape-test--with-watches
    (setq connection "ERROR: no paused connection")
    (kargu-dape-watch "value" nil (lambda (text) (push text results)))
    (should (equal results '("ERROR: no paused connection")))
    (should-not requests)
    (should (= (hash-table-count kargu-dape--watches) 0))
    (should-not kargu-async--pending)))

(provide 'tests/test-dape-watch)
;;; test-dape-watch.el ends here
