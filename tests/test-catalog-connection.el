;;; test-catalog-connection.el --- Owned catalog credential contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise the real asynchronous credential boundary, origin cleanup and
;; native loopback GET.  All credentials and files are synthetic and local.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-native-model-catalog)

(defmacro kargu-catalog-connection-test--pending (&rest body)
  "Run BODY with a delayed credential adapter and a captured native GET port."
  (declare (indent 0) (debug t))
  `(let* ((kargu-application--bound (kargu-application-create))
          (kargu-providers--table (copy-hash-table kargu-providers--table))
          (kargu-api-key nil)
          (provider "catalog-credential-fixture")
          (origin (generate-new-buffer " *catalog credential origin*"))
          (headers (list (cons "x-tenant" (copy-sequence "original"))))
          pending task options snapshot result host hook (cleanups 0) (posts 0) (cancels 0)
          (send (symbol-function 'kargu-catalog-request--send))
          (kargu-config-credential-adapter
           (lambda (_provider target child)
             (setq host target pending child)
             (kargu-async-add-cleanup child (lambda () (cl-incf cleanups))))))
     (unwind-protect
         (progn
           ;; These bindings form the fixture interface; individual cases use subsets.
           (ignore pending task options snapshot result host hook cleanups posts cancels)
           (kargu-register-provider :id provider :api "https://fixture.invalid/v1"
                                    :format 'openapi :extra-headers headers)
           (kargu-test-config-publish (kargu-config-service-context) nil "/synthetic" "revision-1")
           (cl-letf (((symbol-function 'kargu-transport-request)
                      (lambda (_method _url &rest arguments)
                        (cl-incf posts) (setq options arguments) :synthetic-handle))
                     ((symbol-function 'kargu-transport-cancel)
                      (lambda (_handle) (cl-incf cancels)))
                     ((symbol-function 'kargu-catalog-request--send)
                      (lambda (parent connection &rest arguments)
                        (setq snapshot connection) (apply send parent connection arguments))))
             (with-current-buffer origin
               (setq task (kargu-test-await-catalog-start #'kargu-api-list-models (lambda (value) (setq result value)) provider)
                     hook (car kill-buffer-hook)))
             ,@body))
       (when task (kargu-async-cancel task))
       (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest kargu-catalog-connection-freezes-target-across-selection-and-application-test ()
  "Delayed credentials retain their application, provider, wire and raw bindings."
  (kargu-catalog-connection-test--pending
   (should pending) (should (zerop posts))
   (should (equal host "fixture.invalid"))
   (with-current-buffer origin (setf (kargu-selection-provider) "another-provider"))
   (setcdr (car headers) "changed")
   (kargu-register-provider :id provider :api "https://fixture.invalid/v1" :format 'anthropic)
   (let ((kargu-application--bound (kargu-application-create)))
     (kargu-test-config-publish (kargu-config-service-context) nil "/other" "other-revision")
     (kargu-test-config-publish (kargu-config-service-context) nil "/other" "second-revision")
     (kargu-async-finish pending (kargu-ok "synthetic-delayed-key")))
   (kargu-bridge-test--wait (lambda () (> posts 0)))
   (should (= posts 1)) (should (= cleanups 1))
   (should (eq (plist-get options :application) kargu-application--bound))
   (should (equal (plist-get options :provider) provider))
   (should (equal (plist-get options :wire) (kargu-provider-format-record 'openapi)))
   (should (equal (kargu-aget (kargu-aget (plist-get options :auth) "extra_headers") "x-tenant") "original"))
   (should (equal (kargu-aget (plist-get options :auth) "key") "synthetic-delayed-key"))
   (should-not (string-search "synthetic-delayed-key" (prin1-to-string snapshot)))
   (kargu-async-cancel task)
   (should (= cancels 1))
   (should-not (kargu-connection-snapshot-secret snapshot))
   (should (equal (kargu-aget (plist-get options :auth) "key")
                  (make-string (length "synthetic-delayed-key") 0)))
   (funcall (plist-get options :then) "{\"models\":[]}")
   (should-not result)))

(ert-deftest kargu-catalog-connection-revocation-before-get-releases-children-test ()
  "Cancel, owner closure, timeout and stale config/session cannot issue a GET."
  (dolist (ending '(cancel kill mode timeout config session))
    (kargu-catalog-connection-test--pending
     (pcase ending
       ('cancel (kargu-async-cancel task))
       ('kill (kill-buffer origin))
       ('mode (with-current-buffer origin (emacs-lisp-mode)))
       ('timeout (kargu-async-finish task nil "Request timed out"))
       ('config (kargu-test-config-publish (kargu-config-service-context) nil "/synthetic" "revision-2"))
       ('session (with-current-buffer origin
                   (setq kargu-session--context (kargu-test-session-with-history)))))
     (kargu-async-finish pending (kargu-ok "late-synthetic-key"))
     (should-not (kargu-async-pending-p task))
     (should-not (kargu-async-pending-p pending))
     (should-not (kargu-async-task-timer task))
     (should-not (kargu-async-task-children task))
     (should (= cleanups 1)) (should (zerop posts))
     (should-not snapshot)
     (when (memq ending '(timeout config session))
       (should (kargu-aget result "error")))
     (when (buffer-live-p origin)
       (with-current-buffer origin
         (should-not (memq hook kill-buffer-hook)))))))

(ert-deftest kargu-catalog-connection-error-is-redacted-and-delivers-once-test ()
  "A credential adapter's failure does not leak its raw message into the UI."
  (kargu-catalog-connection-test--pending
   (kargu-async-finish pending (kargu-err "synthetic-error-secret" :auth-unavailable))
   (should (kargu-aget result "error"))
   (should-not (string-search "synthetic-error-secret" (prin1-to-string result)))
   (kargu-async-finish pending (kargu-ok "late-synthetic-key"))
   (should (zerop posts)) (should (= cleanups 1))))

(ert-deftest kargu-catalog-connection-bound-chat-cannot-lend-wire-or-key-test ()
  "Independent catalog discovery does not borrow a running chat's connection."
  (kargu-catalog-connection-test--pending
   (kargu-async-cancel task)
   (let ((kargu-connection--bound
          (kargu-connection-snapshot--create
           :provider "opencode" :endpoint "https://foreign.invalid/v1"
           :settings '(:wire (:auth x-api-key) :header-overrides (("x-tenant" . "foreign"))))))
     (with-current-buffer origin (setq task (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode"))))
   (should (= posts 1))
   (should (equal (plist-get options :provider) "opencode"))
   (should (equal (plist-get options :wire) (kargu-provider-format-record 'openapi)))
   (should (eq (kargu-aget (plist-get options :auth) "key") :json-null))
   (should-not (equal (kargu-aget (kargu-aget (plist-get options :auth) "extra_headers") "x-tenant") "foreign"))))

(ert-deftest kargu-catalog-connection-real-plaintext-worker-to-native-get-test ()
  "A real child resolves a synthetic auth file before Rust sends a real GET."
  (kargu-bridge-test--with-core
   (kargu-model-catalog-test--with-server "{\"data\":[{\"id\":\"private-model\"}]}"
					  (let* ((file (make-temp-file "kargu-catalog-auth-"))
						 (auth-sources (list file)) (kargu-api-key nil)
						 (kargu-config-credential-adapter nil) (kargu-config-worker-runner-fn nil)
						 done result)
					    (unwind-protect
						(progn
						  (write-region "machine 127.0.0.1 login apikey password synthetic-catalog-key\n" nil file nil 'silent)
						  (set-file-modes file #o600)
						  (kargu-register-provider :id provider :api url :models-api url :format 'openapi)
						  (cl-letf (((symbol-function 'auth-source-search)
							     (lambda (&rest _) (ert-fail "No UI-thread auth-source search"))))
						    (let ((task (kargu-api-list-models
								 (lambda (models) (setq result models done t)) provider)))
						      (should (kargu-async-pending-p task))
						      (should (zerop posts))
						      (kargu-bridge-test--wait (lambda () done))
						      (should-not (kargu-async-task-children task))
						      (should-not (kargu-async-task-timer task))))
						  (should-not (kargu-aget result "error"))
						  (should (= posts 1))
						  (should (string-match-p "[Aa]uthorization: Bearer synthetic-catalog-key" captured))
						  (should (equal (kargu-selection-model-candidates provider) '("private-model"))))
					      (delete-file file))))))

(ert-deftest kargu-catalog-connection-killing-origin-stops-real-credential-child-test ()
  "Origin closure kills a real slow worker and releases its private buffer."
  (let* ((origin (generate-new-buffer " *catalog real child*"))
         (kargu-config-credential-adapter nil)
         (kargu-api-key nil)
         (kargu-config-worker-runner-fn
          (lambda (_provider _host child _timeout)
            (kargu-config-worker-start child "(sleep-for 10)" nil :name "catalog-slow")))
         task process buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) nil))
                  ((symbol-function 'kargu-transport-request)
                   (lambda (&rest _) (ert-fail "No GET before credential completion"))))
          (with-current-buffer origin (setq task (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "openrouter")))
          (setq process (get-process "kargu-catalog-slow-worker") buffer (process-buffer process))
          (should (process-live-p process))
          (kill-buffer origin)
          (should-not (process-live-p process))
          (should-not (buffer-live-p buffer))
          (should-not (kargu-async-task-timer task))
          (should-not (kargu-async-task-children task)))
      (when task (kargu-async-cancel task))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(provide 'tests/test-catalog-connection)
;;; test-catalog-connection.el ends here
