;;; test-config-policy.el --- Native config authority and lost replies -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real native prepare/commit replies are held at the editor delivery boundary.
;; No policy engine or credential lookup is replaced with a second implementation.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)

(defmacro kargu-config-policy-test--held (method &rest body)
  "Run BODY with one real METHOD reply held after native execution."
  (declare (indent 1) (debug t))
  `(kargu-bridge-test--with-core
    (let* ((kargu-application--bound (kargu-application-create))
           (call (symbol-function 'kargu-bridge-call))
           (method ,method) held receipt task result (aborts 0) (commits 0))
      (kargu-test-config-publish (kargu-config-service-context) '(:provider "stable") "/fixture" "stable")
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (connection name params callback &rest options)
                       (when (equal name "configuration/abort") (cl-incf aborts))
                       (when (equal name "configuration/commit") (cl-incf commits))
                       (apply call connection name params
                              (if (and (equal name method) (null held))
                                  (lambda (value failure)
                                    (setq receipt value held (lambda () (funcall callback value failure))))
                                callback) options))))
            (setq task (kargu-config-refresh-async (lambda (value) (setq result value)) :defaults-only t))
             (kargu-bridge-test--wait (lambda () held))
             (should (hash-table-p receipt))
             ,@body)
        (when task (kargu-async-cancel task))))))

(ert-deftest kargu-config-policy-cancelled-prepare-aborts-late-ticket-test ()
  "A cancelled root drains a late acquisition, never issuing commit."
  (kargu-config-policy-test--held "configuration/prepare"
				  (kargu-async-cancel task)
				  (funcall held)
				  (should (= aborts 1))
				  (should (= commits 0))
				  (should-not result)
				  (should (= (kargu-config-revision) 1))
				  (let* ((scope (kargu-bridge-application-current-scope (kargu-application-context) conn))
					 (reply (kargu-bridge-test--call
						 conn "configuration/commit"
						 (kargu-bridge--object "scope" scope "arguments"
								       (kargu-bridge--object "capture_id" (gethash "capture_id" receipt)
											     "context" (kargu-bridge-config-context))))))
				    (should (cadr reply)))))

(ert-deftest kargu-config-policy-lost-commit-ack-never-authorizes-old-revision-test ()
  "A committed but unobserved head fails closed until explicit refresh."
  (kargu-config-policy-test--held "configuration/commit"
				  (should (= (gethash "revision" receipt) 2))
				  (should (= (kargu-config-revision) 1))
				  (kargu-async-cancel task)
				  (let ((kargu-config-credential-adapter (lambda (&rest _) (ert-fail "Stale config unlocked credentials"))))
				    (should (kargu-err-p
					     (kargu-test-await
					      (lambda (done) (kargu-connection-resolve-async "stable" "m" :callback done))))))
				  (funcall held)
				  (should-not result)
				  (should (= (kargu-config-revision) 1))
				  (should (= aborts 0))
				  (should (kargu-ok-p
					   (kargu-test-await (lambda (done) (kargu-config-refresh-async done :defaults-only t)))))
    (should (= (kargu-config-revision) 2))))

(ert-deftest kargu-config-policy-replaced-session-on-same-epoch-rejects-ticket-test ()
  "Connection identity alone cannot authorize a replaced native session."
  (kargu-config-policy-test--held "configuration/prepare"
    (let* ((app (kargu-application-context))
           (binding (gethash :native-core (kargu-application-services app)))
           (scope (kargu-bridge-application-scope binding))
           (reply (kargu-bridge-test--call conn "session/create"
                                          (kargu-bridge--object "application_id" (gethash "application_id" scope)))))
      (should-not (cadr reply))
      (setf (kargu-bridge-application-scope binding) (car reply))
      (funcall held)
      (should (kargu-err-p result))
      (should (= (kargu-config-revision) 1))
      (should (= aborts 1))
      (should (= commits 0)))))

(ert-deftest kargu-config-policy-environment-and-options-freeze-before-prepare-yield-test ()
  "Preparation never reads replacement globals or mutable environment strings."
  (kargu-bridge-test--with-core
   (let* ((kargu-application--bound (kargu-application-create))
          (kargu-api-key nil)
          (process-environment (copy-sequence process-environment))
          (entry (copy-sequence "KARGU_POLICY_TOKEN=captured-private"))
          (call (symbol-function 'kargu-bridge-call)) held task view)
     (push entry process-environment)
     (unwind-protect
         (cl-letf (((symbol-function 'kargu-bridge-call)
                    (lambda (connection method params callback &rest options)
                      (apply call connection method params
                             (if (equal method "configuration/prepare")
                                 (lambda (value failure) (setq held (lambda () (funcall callback value failure))))
                               callback) options))))
           (setq task (kargu-bridge-config-publish
                       (kargu-bridge--object "path" "/synthetic/config" "digest" (make-string 64 ?a)
                                             "config" (kargu-test-config-document
                                                       '(:provider "custom" :providers (("custom" :apikey "${KARGU_POLICY_TOKEN}")))))
                       1 (lambda (value failure) (should-not failure) (setq view value))
                       :application (kargu-application-context)))
           (kargu-bridge-test--wait (lambda () held))
           (clear-string entry)
           (setq kargu-api-key "replacement-private")
           (funcall held)
           (kargu-bridge-test--wait (lambda () view))
           (should (equal (gethash "secret" (gethash "credential" (gethash "default" view))) "captured-private")))
       (when task (kargu-async-cancel task))))))

(ert-deftest kargu-config-policy-deleted-editor-authorities-stay-removed-test ()
  "The editor cannot increment revisions or reproduce Rust credential policy."
  (dolist (function '(kargu-config-publish kargu-config-bump-revision
					   kargu--provider-plist kargu--provider-toml-plist
					   kargu--expand-env-refs kargu--provider-env-api-key
					   kargu--resolve-direct-api-key kargu-provider-valid-key-p))
    (should-not (fboundp function))))

(ert-deftest kargu-config-policy-query-closed-or-expired-parent-never-sends-test ()
  "Read policy ports reject dead parents before RPC or native owner acquisition."
  (kargu-test-config-publish (kargu-config-service-context) nil "/fixture" "admission")
  (dolist (ending '(cancel expired))
    (let ((parent (kargu-async-start #'ignore :owner nil)) child)
      (unwind-protect
          (progn
            (if (eq ending 'cancel) (kargu-async-cancel parent)
              (setf (kargu-async-task-deadline parent) (1- (float-time))))
            (cl-letf (((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "Dead parent sent RPC")))
                      ((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "Dead parent started core"))))
              (setq child (kargu-bridge-config-query "configuration/snapshot" (kargu-bridge--object) #'ignore
                                                     :parent parent :application (kargu-application-context))))
            (should-not (kargu-async-pending-p child))
            (should-not (kargu-async-task-timer child)))
        (kargu-async-cancel parent)))))

(provide 'tests/test-config-policy)
;;; test-config-policy.el ends here
