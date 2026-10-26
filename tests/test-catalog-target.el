;;; test-catalog-target.el --- Native catalog target preparation contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Withhold real target replies to test ownership between policy and credential
;; phases.  Ordinary catalog tests still exercise the actual Rust policy port.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-native-model-catalog)

(defmacro kargu-catalog-target-test--held (&rest body)
  "Run BODY while a real native target response is held before editor delivery."
  (declare (indent 0) (debug t))
  `(kargu-bridge-test--with-core
    (let* ((origin (generate-new-buffer " *catalog target origin*"))
           (kargu-application--bound (kargu-application-create))
           (kargu-providers--table (copy-hash-table kargu-providers--table))
           (kargu-api-key nil)
           (call (symbol-function 'kargu-bridge-call))
           held task credential result url options (posts 0)
           (kargu-config-credential-adapter
            (lambda (_provider _host child) (setq credential child))))
      (unwind-protect
          (progn
            (ignore held task credential result url options posts)
            (kargu-register-provider :id "held-target" :api "https://fixture.invalid/v1" :format 'openapi)
            (cl-letf (((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) nil))
                      ((symbol-function 'kargu-bridge-call)
                       (lambda (connection method params callback &rest arguments)
                         (apply call connection method params
                                (if (equal method "provider/catalogTarget")
                                    (lambda (value failure) (setq held (lambda () (funcall callback value failure))))
                                  callback) arguments)))
                      ((symbol-function 'kargu-transport-request)
                       (lambda (_method target &rest arguments)
                         (setq url target options arguments) (cl-incf posts) nil)))
              (with-current-buffer origin
                (setq task (kargu-api-list-models (lambda (value) (setq result value)) "held-target")))
              (kargu-bridge-test--wait (lambda () held))
              ,@body))
        (when task (kargu-async-cancel task))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest kargu-catalog-target-revocation-before-policy-never-resolves-key-or-gets-test ()
  "A cancelled, closed, stale or expired policy waiter cannot start credentials."
  (dolist (ending '(cancel kill mode timeout config endpoint native-close))
    (kargu-catalog-target-test--held
     (should-not credential) (should (zerop posts))
     (should (eq (kargu-bridge-application-state (gethash :native-core (kargu-application-services kargu-application--bound))) :ready))
     (pcase ending
       ('cancel (kargu-async-cancel task))
       ('kill (kill-buffer origin))
       ('mode (with-current-buffer origin (emacs-lisp-mode)))
       ('timeout (kargu-async-finish task nil "Request timed out"))
       ('config (kargu-test-config-invalidate))
       ('native-close (puthash :native-core (kargu-bridge-application--make :connection conn :state :closed)
                               (kargu-application-services kargu-application--bound)))
       ('endpoint (kargu-register-provider :id "held-target" :api "https://changed.invalid/v1" :format 'openapi)))
     (funcall held)
     (when (kargu-async-pending-p task)
       (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p task)))))
     (should-not credential) (should (zerop posts))
     (should-not (kargu-async-pending-p task))
     (should-not (kargu-async-task-children task))
     (should-not (kargu-async-task-timer task)))))

(ert-deftest kargu-catalog-target-registry-mutation-cannot-rewrite-captured-intent-test ()
  "Registry changes during native projection cannot rewrite the chosen wire/URL."
  (kargu-catalog-target-test--held
   (kargu-register-provider :id "held-target" :api "https://fixture.invalid/v1"
                            :models-api "https://new.invalid/models" :format 'anthropic)
   (let ((kargu-application--bound (kargu-application-create)))
     (kargu-test-config-invalidate)
     (funcall held)
     (kargu-bridge-test--wait (lambda () credential))
     (should credential)
     (kargu-async-finish credential (kargu-ok "synthetic-held-key")))
   (kargu-bridge-test--wait (lambda () (> posts 0)))
   (should (= posts 1))
   (should (equal url "https://fixture.invalid/v1/models"))
   (should (equal (plist-get options :wire) (kargu-provider-format-record 'openapi)))
   (should (eq (plist-get options :application) kargu-application--bound))
   (should (eq (plist-get options :connection) conn))
   (should-not result)))

(ert-deftest kargu-catalog-target-old-core-rejects-before-credentials-or-owner-start-test ()
  "Missing target capability is an explicit failure, never a Lisp policy fallback."
  (let ((kargu-application--bound (kargu-application-create)) result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create :state 'ready :capabilities ["api_model_catalog"]) nil)
                 #'ignore))
              ((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) (ert-fail "No key lookup")))
              ((symbol-function 'kargu-bridge-application-ensure) (lambda (&rest _) (ert-fail "No owner startup")))
              ((symbol-function 'kargu-transport-request) (lambda (&rest _) (ert-fail "No GET"))))
      (let ((task (kargu-api-list-models (lambda (value) (setq result value)) "opencode")))
        (should (kargu-aget result "error"))
        (should-not (kargu-async-task-timer task))
        (should-not (kargu-async-task-children task))))))

(ert-deftest kargu-catalog-target-closed-parent-never-starts-a-core-test ()
  "A port invoked with an already-closed parent cannot acquire a startup waiter."
  (let ((parent (kargu-async-start #'ignore :owner nil :parent nil)))
    (kargu-async-cancel parent)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No startup after revocation"))))
      (let ((child (kargu-bridge-catalog-target
                    (kargu-bridge--object) #'ignore :parent parent :application (kargu-application-create))))
        (should-not (kargu-async-pending-p child))
        (should-not (kargu-async-task-timer child))
        (should-not (kargu-async-task-children parent))))))

(ert-deftest kargu-catalog-target-captures-dto-before-startup-yield-test ()
  "Mutating the caller's DTO during startup cannot change native target intent."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (base (copy-sequence "https://original.invalid/v1"))
          (arguments (kargu-bridge--object "provider" "fixture" "configuration_revision" 3 "api_base" base))
          release done result failure)
     (cl-letf (((symbol-function 'kargu-bridge-ensure)
                (lambda (callback) (setq release (lambda () (funcall callback conn nil))) #'ignore)))
       (kargu-bridge-catalog-target arguments
                                    (lambda (value error-data _connection)
                                      (setq result value failure error-data done t))
                                    :application app))
     (aset base 8 ?X)
     (puthash "provider" "foreign" arguments)
     (funcall release)
     (kargu-bridge-test--wait (lambda () done))
     (should-not failure)
     (should (equal (gethash "provider" result) "fixture"))
     (should (equal (gethash "url" result) "https://original.invalid/v1/models")))))

(ert-deftest kargu-catalog-target-malformed-projection-never-starts-credentials-test ()
  "Foreign provider/revision and malformed target fields fail before key lookup."
  (dolist (field '("provider" "configuration_revision" "authentication" "url"))
    (kargu-catalog-target-test--held
     (let ((receive (symbol-function 'kargu-catalog-request--targeted)))
       (cl-letf (((symbol-function 'kargu-catalog-request--targeted)
                  (lambda (parent value failure connection &rest arguments)
                    (puthash field :json-null value)
                    (apply receive parent value failure connection arguments))))
         (funcall held)))
     (should (kargu-aget result "error"))
     (should-not credential) (should (zerop posts)))))

(ert-deftest kargu-catalog-target-lost-epoch-cannot-reconnect-for-get-test ()
  "A connection lost after target preparation is never replaced for that GET."
  (kargu-bridge-test--with-core
   (let* ((kargu-application--bound (kargu-application-create))
          (kargu-providers--table (copy-hash-table kargu-providers--table))
          (kargu-api-key nil) credential task result
          (kargu-config-credential-adapter (lambda (_provider _host child) (setq credential child))))
     (kargu-register-provider :id "lost-target" :api "https://fixture.invalid/v1" :format 'openapi)
     (cl-letf (((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) nil)))
       (setq task (kargu-api-list-models (lambda (value) (setq result value)) "lost-target"))
       (kargu-bridge-test--wait (lambda () credential))
       (kargu-bridge-stop conn)
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-status conn) 'closed)))
       (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No new epoch"))))
         (kargu-async-finish credential (kargu-ok "synthetic-lost-key")))
       (should (kargu-aget result "error"))
       (should-not (kargu-async-task-timer task))
       (should-not (kargu-async-task-children task))))))

(ert-deftest kargu-catalog-target-query-reaches-real-get-without-path-injection-test ()
  "Native path derivation changes the path, never appends /models to the query."
  (kargu-bridge-test--with-core
   (kargu-model-catalog-test--with-server "{\"data\":[{\"id\":\"query-model\"}]}"
					  (setq url (replace-regexp-in-string "/models\\'" "/v1?tenant=synthetic" url))
					  (kargu-register-provider :id provider :api url :format 'openapi :keyless t)
					  (let (done result)
					    (kargu-api-list-models (lambda (value) (setq result value done t)) provider)
					    (kargu-bridge-test--wait (lambda () done))
					    (should-not (kargu-aget result "error"))
					    (should (= posts 1))
					    (should (string-prefix-p "GET /v1/models?tenant=synthetic " captured))))))

(ert-deftest kargu-catalog-target-legacy-policy-functions-are-removed-test ()
  "Editor consumers no longer contain URL derivation or public-auth policy."
  (dolist (symbol '(kargu-catalog-request--url kargu-provider-native-models-path kargu-provider-public-models-p))
    (should-not (fboundp symbol))))

(provide 'tests/test-catalog-target)
;;; test-catalog-target.el ends here
