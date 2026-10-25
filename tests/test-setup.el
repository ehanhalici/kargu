;;; test-setup.el --- Shared connection setup lifecycle contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Controlled refresh/credential boundaries plus a real config child fixture.
;; No test contacts an upstream model endpoint or unlocks a real credential.

;;; Code:

(require 'ert)
(require 'tests/test-connection-native)
(require 'tests/test-modules)
(require 'kargu/config/setup)

(defmacro kargu-setup-test--pending (&rest body)
  "Run BODY with staged config/credential children and captured UI output."
  (declare (indent 0) (debug t))
  `(let* ((origin (generate-new-buffer " *setup origin*"))
          (kargu-application--bound (kargu-application-create))
          (kargu-providers--table (copy-hash-table kargu-providers--table))
          (kargu-api-key nil)
          task refresh credential snapshot key-copy messages logs host
          (credential-cleanups 0)
          (resolve (symbol-function 'kargu-connection-resolve-async))
          (report (symbol-function 'kargu-config--report-setup))
          (kargu-config-credential-adapter
           (lambda (provider target child)
             (should (equal provider "setup-fixture"))
             (setq credential child host target)
             (kargu-async-add-cleanup child (lambda () (cl-incf credential-cleanups))))))
     (unwind-protect
         (progn
           (ignore task refresh credential snapshot key-copy messages logs host credential-cleanups)
           (kargu-register-provider :id "setup-fixture" :api "https://setup.invalid/v1" :format 'openapi)
           (with-current-buffer origin
             (setq kargu-session--context
                   (kargu-test-session-with-history :provider "setup-fixture" :model "captured-model")))
           (cl-letf (((symbol-function 'kargu-config-refresh-async)
                      (lambda (callback &rest options)
                        (setq refresh (kargu-async-start
                                       (lambda (value _error) (funcall callback value))
                                       :owner nil :parent (plist-get options :parent)))))
                     ((symbol-function 'kargu-connection-resolve-async)
                      (lambda (provider model &rest options)
                        (let ((callback (plist-get options :callback)))
                          (apply resolve provider model
                                 :callback (lambda (value)
                                             (when (kargu-ok-p value) (setq snapshot (kargu-result-value value)))
                                             (funcall callback value))
                                 (cl-loop for (key value) on options by #'cddr
                                          unless (eq key :callback) append (list key value))))))
                     ((symbol-function 'kargu-config--report-setup)
                      (lambda (value)
                        (setq key-copy (kargu-result-value value)) (funcall report value)))
                     ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                     ((symbol-function 'kargu--missing-dependencies) (lambda () nil))
                     ((symbol-function 'kargu-transport-request)
                      (lambda (&rest _) (ert-fail "Setup never sends a model request")))
                     ((symbol-function 'kargu-bridge-ensure)
                      (lambda (&rest _) (ert-fail "Setup never starts model metadata discovery")))
                     ((symbol-function 'message)
                      (lambda (format &rest args) (push (apply #'format format args) messages)))
                     ((symbol-function 'kargu-log)
                      (lambda (_level format &rest args) (push (apply #'format format args) logs))))
             (with-current-buffer origin (setq task (kargu-check-setup)))
             ,@body))
       (when task (kargu-async-cancel task))
       (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest kargu-setup-shares-connection-owner-and-wipes-report-credentials-test ()
  "Setup reports its frozen target, not a foreign application's bound connection."
  (kargu-setup-test--pending
    (should (kargu-async-task-p task)) (should-not credential)
    (let ((kargu-application--bound (kargu-application-create))
          (kargu-connection--bound
           (kargu-connection-snapshot--create :provider "foreign" :model "foreign-model"
                                              :endpoint "https://foreign.invalid/v1")))
      (kargu-async-finish refresh (kargu-ok nil))
      (should credential) (should (equal host "setup.invalid"))
      (kargu-config-bump-revision)
      (kargu-async-finish credential (kargu-ok "synthetic-owned-key")))
    (should (= credential-cleanups 1))
    (should (cl-some (lambda (text) (string-search "provider=setup-fixture model=captured-model" text)) messages))
    (should-not (string-search "synthetic-owned-key" (prin1-to-string (append logs messages))))
    (should-not (kargu-connection-snapshot-secret snapshot))
    (should (equal key-copy (make-string (length "synthetic-owned-key") 0)))
    (should-not (kargu-async-task-children task))
    (should-not (kargu-async-task-timer task))
    (with-current-buffer origin (should-not kargu-setup--task))))

(ert-deftest kargu-setup-cancel-and-origin-close-revoke-both-phases-test ()
  "Cancel/kill/mode/deadline close child work in config and credential phases."
  (dolist (phase '(config credential))
    (dolist (ending '(cancel kill mode timeout))
      (kargu-setup-test--pending
        (when (eq phase 'credential) (kargu-async-finish refresh (kargu-ok nil)))
        (let* ((child (if (eq phase 'credential) credential refresh))
               (hook (with-current-buffer origin (car kill-buffer-hook))))
          (pcase ending
            ('cancel (kargu-async-cancel task))
            ('kill (kill-buffer origin))
            ('mode (with-current-buffer origin (emacs-lisp-mode)))
            ('timeout (kargu-async-finish task nil "Request timed out")))
          (kargu-async-finish child (kargu-ok "late-synthetic-key"))
          (should-not (kargu-async-pending-p child))
          (should-not (kargu-async-task-children task))
          (should-not (kargu-async-task-timer task))
          (should-not snapshot)
          (should-not (cl-some (lambda (text) (string-search "kargu ready" text)) messages))
          (when (eq phase 'credential) (should (= credential-cleanups 1)))
          (when (buffer-live-p origin)
            (with-current-buffer origin
              (should-not (memq hook kill-buffer-hook))
              (should-not kargu-setup--task))))))))

(ert-deftest kargu-setup-selection-change-rejects-late-key-and-wipes-scope-test ()
  "Selection changes never report the new provider with the old credential."
  (kargu-setup-test--pending
    (kargu-async-finish refresh (kargu-ok nil))
    (with-current-buffer origin (kargu-selection-update :provider "another-provider" :model "new-model"))
    (kargu-async-finish credential (kargu-ok "late-synthetic-key"))
    (should snapshot)
    (should-not (kargu-connection-snapshot-secret snapshot))
    (should-not key-copy)
    (should-not (cl-some (lambda (text) (string-search "kargu ready" text)) messages))))

(ert-deftest kargu-setup-config-failure-and-credential-errors-do-not-echo-secrets-test ()
  "Both phases finish once with no raw adapter/config error in UI or logs."
  (dolist (phase '(config credential))
    (kargu-setup-test--pending
      (when (eq phase 'credential) (kargu-async-finish refresh (kargu-ok nil)))
      (let ((child (if (eq phase 'credential) credential refresh)))
        (kargu-async-finish child (kargu-err "synthetic-private-error" :unavailable))
        (kargu-async-finish child (kargu-ok "late-key")))
      (should (= (length messages) 1))
      (should-not snapshot)
      (should-not (string-search "synthetic-private-error" (prin1-to-string (append logs messages))))
      (should-not (kargu-async-task-timer task)))))

(ert-deftest kargu-setup-repeated-check-only-replaces-origin-root-test ()
  "Replacing setup cancels its old child, not another buffer's setup check."
  (kargu-setup-test--pending
    (let ((first task) (first-child refresh) other other-child
          (other-origin (generate-new-buffer " *other setup*")))
      (unwind-protect
          (progn
            (with-current-buffer other-origin (setq other (kargu-check-setup) other-child refresh))
            (with-current-buffer origin (setq task (kargu-check-setup)))
            (should-not (kargu-async-pending-p first))
            (should-not (kargu-async-pending-p first-child))
            (should (kargu-async-pending-p task))
            (should (kargu-async-pending-p other))
            (should (kargu-async-pending-p other-child)))
        (when (buffer-live-p other-origin) (kill-buffer other-origin)))
      (should-not (kargu-async-pending-p other))
      (should-not (kargu-async-pending-p other-child)))))

(ert-deftest kargu-setup-report-error-still-wipes-credential-scope-test ()
  "A failing report cannot bypass the private scope and key-copy cleanup."
  (kargu-setup-test--pending
    (kargu-async-finish refresh (kargu-ok nil))
    (cl-letf (((symbol-function 'kargu-config--report-setup)
               (lambda (value)
                 (setq key-copy (kargu-result-value value))
                 (error "Synthetic report failure"))))
      (kargu-async-finish credential (kargu-ok "synthetic-error-key")))
    (should snapshot)
    (should-not (kargu-connection-snapshot-secret snapshot))
    (should (equal key-copy (make-string (length "synthetic-error-key") 0)))
    (should-not (kargu-async-task-timer task))
    (should-not (kargu-async-task-children task))))

(ert-deftest kargu-setup-cold-schema-autoload-keeps-setup-independent-of-api-test ()
  "A fresh schema-only process can autoload setup without the API facade."
  (kargu-module-test--evaluate
   '((require 'kargu/config/schema)
     (cl-assert (autoloadp (symbol-function 'kargu-check-setup)))
     (let ((kargu-api-key "synthetic-cold-key") messages)
       (cl-letf (((symbol-function 'kargu--provider-name) (lambda () "openrouter"))
                 ((symbol-function 'kargu--model) (lambda () "cold-model"))
                 ((symbol-function 'kargu--missing-dependencies) (lambda () nil))
                 ((symbol-function 'kargu-deps-missing) (lambda () nil))
                 ((symbol-function 'message)
                  (lambda (format &rest args) (push (apply #'format format args) messages)))
                 ((symbol-function 'kargu-config-refresh-async)
                  (lambda (callback &rest options)
                    (let ((task (kargu-async-start
                                 (lambda (value _error) (funcall callback value))
                                 :parent (plist-get options :parent) :owner nil)))
                      (kargu-async-finish task (kargu-ok nil)) task))))
         (let ((task (kargu-check-setup)))
           (cl-assert (not (kargu-async-pending-p task)))
           (cl-assert (null kargu-setup--task))
           (cl-assert (cl-some (lambda (text) (string-search "kargu ready" text)) messages))
           (cl-assert (not (featurep 'kargu/api)))
           (cl-assert (not (fboundp 'kargu-config-resolve-api-key-async))))))) t))

(ert-deftest kargu-setup-placeholder-warning-never-prints-key-test ()
  "Even a configured key ending in ellipsis is not safe to print as a placeholder."
  (kargu-setup-test--pending
    (kargu-async-finish refresh (kargu-ok nil))
    (kargu-async-finish credential (kargu-ok "synthetic-sensitive-prefix..."))
    (should (cl-some (lambda (text) (string-search "placeholder" text)) logs))
    (should-not (string-search "synthetic-sensitive-prefix" (prin1-to-string (append logs messages))))
    (should-not (kargu-connection-snapshot-secret snapshot))))

(ert-deftest kargu-setup-real-config-worker-reports-and-cleans-without-native-request-test ()
  "The public setup command uses a real config child but no model/metadata request."
  (kargu-test-with-real-connection
    (let (messages snapshot (resolve (symbol-function 'kargu-connection-resolve-async)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages)))
                ((symbol-function 'kargu--missing-dependencies) (lambda () nil))
                ((symbol-function 'kargu-transport-request) (lambda (&rest _) (ert-fail "No setup HTTP")))
                ((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No metadata startup")))
                ((symbol-function 'kargu-connection-resolve-async)
                 (lambda (provider model &rest options)
                   (let ((callback (plist-get options :callback)))
                     (apply resolve provider model
                            :callback (lambda (result)
                                        (when (kargu-ok-p result) (setq snapshot (kargu-result-value result)))
                                        (funcall callback result))
                            (cl-loop for (key value) on options by #'cddr
                                     unless (eq key :callback) append (list key value)))))))
        (let ((task (kargu-check-setup)))
          (should (kargu-async-pending-p task))
          (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p task))))
          (should-not (kargu-async-task-children task))
          (should-not (kargu-async-task-timer task))
          (should snapshot)
          (should-not (kargu-connection-snapshot-secret snapshot))
          (should (cl-some (lambda (text) (string-search "provider=g02 model=m" text)) messages)))))))

(ert-deftest kargu-setup-duplicate-credential-facade-is-removed-test ()
  "Only the connection port owns credential dispatch after its last consumer moved."
  (dolist (symbol '(kargu-config-resolve-api-key-async kargu-config--dispatch-key
                    kargu-config--deliver-key-result))
    (should-not (fboundp symbol))))

(provide 'tests/test-setup)
;;; test-setup.el ends here
