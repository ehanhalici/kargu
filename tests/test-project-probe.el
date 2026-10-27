;;; test-project-probe.el --- Native project preparation contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Native filesystem fixtures are complemented by controlled editor replies.
;;; Code:
(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/loop)
(require 'kargu/project-probe)
(require 'kargu/tools/deps)

(defun kargu-probe-test--view (name &optional missing)
  "Construct detached native metadata for NAME, optionally MISSING a CLI."
  (kargu-bridge--object
   "text" "" "language" name "language_name" name "complete" t
   "toolchains" (kargu-bridge--object name (kargu-bridge--object "build_cmd" "fixture build"))
   "executables" (kargu-bridge--object "fixture-cli" (if missing :json-false t))))

(defmacro kargu-probe-test--held (&rest body)
  "Run BODY with `replies' held and exact RPC `cancels' observed."
  (declare (indent 0))
  `(let ((connection (kargu-bridge--connection-create :state 'ready)) replies cancels)
     (cl-letf (((symbol-function 'kargu-project-probe-refresh) kargu-test-real-project-refresh)
               ((symbol-function 'kargu-bridge-ensure)
                (lambda (done) (funcall done connection nil) #'ignore))
               ((symbol-function 'kargu-bridge-probe)
                (lambda (_connection _arguments done &rest _options)
                  (push done replies) (length replies)))
               ((symbol-function 'kargu-bridge-cancel)
                (lambda (_connection id) (push id cancels))))
       ,@body)))

(ert-deftest kargu-probe-newest-intent-detached-view-and-passive-readers-test ()
  "Late or repeated replies cannot overwrite newer immutable observations."
  (with-temp-buffer
    (kargu-probe-test--held
      (let (first second)
        (kargu-project-probe-refresh (lambda (v) (setq first v)))
        (kargu-project-probe-refresh (lambda (v) (setq second v)))
        (funcall (car replies) (kargu-probe-test--view "new") nil)
        (funcall (cadr replies) (kargu-probe-test--view "old") nil)
        (should (kargu-ok-p second))
        (should (kargu-err-p first))
        (puthash "language" "changed" (kargu-result-value second))
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "startup")))
                  ((symbol-function 'file-truename) (lambda (&rest _) (ert-fail "filesystem")))
                  ((symbol-function 'directory-files) (lambda (&rest _) (ert-fail "scan")))
                  ((symbol-function 'executable-find) (lambda (&rest _) (ert-fail "executable probe"))))
          (let ((view (kargu-project-probe-view)))
            (aset (gethash "language" view) 0 ?X)
            (should (equal (gethash "language" (kargu-project-probe-view)) "new"))
            (should (eq (kargu-deps-executable-status "fixture-cli") :present))
            (should (eq (kargu-deps-executable-status "unknown-cli") :unknown))))))))

(ert-deftest kargu-probe-captured-root-session-settings-mode-and-deadline-test ()
  "Changed sources and elapsed deadlines cannot publish stale command metadata."
  (dolist (change '(root session settings mode deadline))
    (with-temp-buffer
      (let ((kargu-deps-mandatory-executables (list (copy-sequence "fixture-cli"))) result)
        (kargu-probe-test--held
          (let ((task (kargu-project-probe-refresh (lambda (v) (setq result v)))))
            (pcase change
              ('root (setq default-directory "/synthetic/changed/"))
              ('session (setq-local kargu-session--context nil) (kargu-session-context))
              ('settings (aset (car kargu-deps-mandatory-executables) 0 ?X))
              ('mode (fundamental-mode))
              ('deadline (setf (kargu-async-task-deadline task) (1- (float-time)))))
            (funcall (car replies) (kargu-probe-test--view "stale") nil)
            (should-not (kargu-project-probe-view))
            (should (or (null result) (kargu-err-p result)))))))))

(ert-deftest kargu-probe-closed-parent-does-not-supersede-live-refresh-test ()
  "Invalid admission cannot invalidate another task's pending intent."
  (with-temp-buffer
    (kargu-probe-test--held
      (kargu-project-probe-refresh #'ignore)
      (let ((intent kargu-project-probe--intent)
            (parent (kargu-async-start #'ignore :parent nil :owner nil)))
        (kargu-async-cancel parent)
        (let ((kargu-async--current-task parent)) (kargu-project-probe-refresh #'ignore))
        (should (eq intent kargu-project-probe--intent))
        (should (= (length replies) 1))
        (funcall (car replies) (kargu-probe-test--view "live") nil)
        (should (equal (gethash "language" (kargu-project-probe-view)) "live"))))))

(ert-deftest kargu-probe-source-isolation-close-and-stop-test ()
  "Two sources share no observations; killing a source cancels only its RPC."
  (let ((one (generate-new-buffer " *probe-one*"))
        (two (generate-new-buffer " *probe-two*")))
    (unwind-protect
        (kargu-probe-test--held
          (with-current-buffer one (kargu-project-probe-refresh #'ignore))
          (with-current-buffer two
            (funcall (car replies) (kargu-probe-test--view "one") nil)
            (should-not (kargu-project-probe-view))
            (kargu-project-probe-refresh #'ignore))
          (should (with-current-buffer one (equal (gethash "language" (kargu-project-probe-view)) "one")))
          (kill-buffer two)
          (funcall (car replies) (kargu-probe-test--view "dead") nil)
          (should (= (length cancels) 2)))
      (dolist (buffer (list one two)) (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest kargu-probe-loop-awaits-fresh-mandatory-cli-and-preserves-unsent-history-test ()
  "Missing native prerequisites or Stop prevent connection and model work."
  (dolist (stop '(nil t))
    (with-temp-buffer
      (let ((kargu--loop-run nil) (kargu--busy nil) (kargu-session-auto-save nil)
            (kargu-deps-mandatory-executables '("fixture-cli"))
            (kargu-deps-mandatory-packages nil) report)
        (kargu-test-mode 'ask)
        (kargu-history-replace '((("role" . "user") ("content" . "previous"))))
        (let ((before (kargu-history-snapshot)))
          (kargu-probe-test--held
            (cl-letf (((symbol-function 'kargu-api-prepare-connection) (lambda (&rest _) (ert-fail "connection")))
                      ((symbol-function 'kargu--loop-request) (lambda (&rest _) (ert-fail "model request"))))
              (kargu-loop-send "unsent" nil (lambda (v) (setq report v)))
              (should (kargu-loop-running-p))
              (when stop (kargu-loop-stop))
              (funcall (car replies) (kargu-probe-test--view "missing" t) nil)
              (should-not (kargu-loop-running-p))
              (should-not (plist-get report :request-started))
              (should (equal before (kargu-history-snapshot))))))))))

(ert-deftest kargu-probe-old-core-fails-before-any-legacy-discovery-test ()
  "A missing capability cannot invoke editor scans or executable discovery."
  (with-temp-buffer
    (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities nil)))
      (cl-letf (((symbol-function 'kargu-project-probe-refresh) kargu-test-real-project-refresh)
                ((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
                ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "unsupported RPC")))
                ((symbol-function 'directory-files) (lambda (&rest _) (ert-fail "fallback scan")))
                ((symbol-function 'executable-find) (lambda (&rest _) (ert-fail "fallback executable"))))
        (should (kargu-err-p (kargu-test-await #'kargu-project-probe-refresh)))))))

(ert-deftest kargu-probe-declarative-custom-profiles-and-strategies-test ()
  "Custom configuration crosses as data and callable discovery fails explicitly."
  (let ((profile (kargu-project-probe--profile "custom" "Custom" 10
                  '((:any "custom.toml" (:extension "xyz"))) '(:build-cmd "custom build"))))
    (should (equal (gethash "kind" (gethash "toolchain" profile)) "static"))
    (should (equal (gethash "kind" (aref (gethash "detectors" profile) 0)) "any")))
  (should-error (kargu-project-probe--condition #'ignore))
  (should-error (kargu-project-probe--profile "custom" "Custom" 1 '("file") #'ignore)))

(ert-deftest kargu-probe-real-cli-admission-rejects-before-connection-test ()
  "Real native metadata rejects a missing mandatory executable without a POST."
  (kargu-bridge-test--with-core
    (with-temp-buffer
      (let ((kargu-permission--override-root (make-temp-file "kargu-probe-admit-" t))
            (kargu-deps-mandatory-executables '("kargu-nonexistent-fixture-cli"))
            (kargu-deps-mandatory-packages nil)
            (kargu--loop-run nil) (kargu--busy nil) (kargu-session-auto-save nil) report)
        (unwind-protect
            (cl-letf (((symbol-function 'kargu-project-probe-refresh) kargu-test-real-project-refresh)
                      ((symbol-function 'kargu-api-prepare-connection) (lambda (&rest _) (ert-fail "connection")))
                      ((symbol-function 'kargu--loop-request) (lambda (&rest _) (ert-fail "model request"))))
              (kargu-test-mode 'ask)
              (kargu-test-await
               (lambda (done) (kargu-loop-send "unsent" nil (lambda (v) (setq report v) (funcall done v)))))
              (should (eq (plist-get report :status) :error))
              (should (string-search "kargu-nonexistent-fixture-cli" (plist-get report :error)))
              (should-not (plist-get report :request-started))
              (should-not (kargu-history-snapshot))
              (should (eq (kargu-deps-executable-status "kargu-nonexistent-fixture-cli") :missing)))
          (delete-directory kargu-permission--override-root t))))))

(provide 'tests/test-project-probe)
;;; test-project-probe.el ends here
