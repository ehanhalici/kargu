;;; tests/test-connection-snapshot.el --- Tests for Connection Snapshot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verification of Contract 4, CONFIG-01, and DEEP-14:
;; 1. Immutability of connection snapshots.
;; 2. Zero secret leakage into summaries, logs, or argv.
;; 3. Callable secret safety: auth-source and secret functions NEVER called
;;    synchronously on the Emacs UI thread (CONFIG-01).
;; 4. Keyless and offline modes.
;; 5. Non-blocking cancellation and cleanup of worker resources.
;; 6. Stale result discard upon config revision change.
;; 7. Retry preservation of connection snapshots.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/core)
(require 'kargu/config)
(require 'kargu/config/connection)
(require 'kargu/config/worker)
(require 'kargu/providers)

(ert-deftest kargu-connection-snapshot-immutable-fields-test ()
  "Connection snapshot slots must be populated and read-only."
  (let* ((scope (kargu-credential-scope--create :raw-secret "sk-test-key-123"))
         (snap (kargu-connection-snapshot--create
                :provider "openai"
                :model "gpt-4o"
                :endpoint "https://api.openai.com/v1"
                :wire-format :openai
                :capabilities '(:tools t :stream t :reasoning nil)
                :config-revision 42
                :credential-scope scope)))
    (should (kargu-connection-snapshot-p snap))
    (should (stringp (kargu-connection-snapshot-id snap)))
    (should (string-prefix-p "conn-" (kargu-connection-snapshot-id snap)))
    (should (equal (kargu-connection-snapshot-provider snap) "openai"))
    (should (equal (kargu-connection-snapshot-model snap) "gpt-4o"))
    (should (equal (kargu-connection-snapshot-endpoint snap) "https://api.openai.com/v1"))
    (should (eq (kargu-connection-snapshot-wire-format snap) :openai))
    (should (equal (kargu-connection-snapshot-capabilities snap)
                   '(:tools t :stream t :reasoning nil)))
    (should (= (kargu-connection-snapshot-config-revision snap) 42))
    (should (eq (kargu-connection-snapshot-credential-scope snap) scope))
    (should (floatp (kargu-connection-snapshot-created-at snap)))
    ;; Verify read-only enforcement
    (dolist (accessor '(kargu-connection-snapshot-provider kargu-connection-snapshot-endpoint
							   kargu-connection-snapshot-config-revision))
      (should-error (eval `(setf (,accessor ',snap) "mutated") t)))))

(ert-deftest kargu-connection-redacted-summary-zero-secret-leakage-test ()
  "Redacted summaries must omit credentials and never leak secrets into prints."
  (let* ((secret "sk-ultra-secret-token-XYZ-987654321")
         (scope (kargu-credential-scope--create :raw-secret secret))
         (snap (kargu-connection-snapshot--create
                :provider "anthropic"
                :model "claude-3-5-sonnet"
                :endpoint "https://api.anthropic.com/v1"
                :wire-format :anthropic
                :capabilities '(:tools t :stream t :reasoning nil)
                :config-revision 7
                :credential-scope scope))
         (summary (kargu-connection-redacted-summary snap))
         (printed (format "%S" summary)))
    (should (listp summary))
    (should (equal (plist-get summary :provider) "anthropic"))
    (should (equal (plist-get summary :model) "claude-3-5-sonnet"))
    (should (equal (plist-get summary :endpoint) "https://api.anthropic.com/v1"))
    (should (eq (plist-get summary :wire-format) :anthropic))
    (should (= (plist-get summary :config-revision) 7))
    ;; Credentials must NOT be in the plist
    (should-not (plist-member summary :secret))
    (should-not (plist-member summary :credential-scope))
    (should-not (plist-member summary :raw-secret))
    ;; Credentials must NOT appear in the formatted string representation
    (should-not (string-search secret printed))
    (should-not (string-search "sk-ultra-secret" printed))))

(ert-deftest kargu-connection-snapshot-secret-and-wipe-lifecycle-test ()
  "Credential scopes allow reading secrets until wiped, after which they are zeroed."
  (let* ((secret-data (copy-sequence "super-confidential-token-555"))
         (scope (kargu-credential-scope--create :raw-secret secret-data))
         (snap (kargu-connection-snapshot--create
                :provider "deepseek"
                :model "deepseek-chat"
                :endpoint "https://api.deepseek.com/v1"
                :wire-format :openai
                :config-revision 1
                :credential-scope scope)))
    (should (equal (kargu-connection-snapshot-secret snap) "super-confidential-token-555"))
    (should-not (kargu-credential-scope-wiped-p scope))
    ;; Wipe credential scope
    (should (kargu-connection-snapshot-wipe snap))
    (should (kargu-credential-scope-wiped-p scope))
    (should-not (kargu-connection-snapshot-secret snap))
    ;; String buffer in memory was cleared
    ;; Scope teardown must not mutate the caller's configuration string.
    (should (equal secret-data "super-confidential-token-555"))))

(ert-deftest kargu-connection-keyless-offline-mode-test ()
  "Native keyless policy needs no auth-source or upstream request."
  (let ((kargu-api-key nil))
    (kargu-test-config-publish (kargu-config-service-context)
                               '(:providers (("ollama" :api "http://localhost:11434/v1" :apikey ""))) "/fixture" "keyless")
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (ert-fail "No keyless lookup"))))
      (let ((result (kargu-test-await (lambda (done) (kargu-connection-resolve-async "ollama" "llama3" :callback done)))))
        (should (kargu-ok-p result))
        (let ((snapshot (kargu-result-value result)))
          (should (equal (kargu-connection-snapshot-provider snapshot) "ollama"))
          (should (equal (kargu-connection-snapshot-endpoint snapshot) "http://localhost:11434/v1"))
          (should (equal (kargu-connection-snapshot-secret snapshot) ""))
          (kargu-connection-snapshot-wipe snapshot))))))

(ert-deftest kargu-connection-callable-secret-never-called-on-ui-thread-test ()
  "Discovery and native policy never invoke an editor callable secret."
  (let ((called 0) (kargu-api-key nil)
        (auth-sources '("~/.authinfo.gpg"))
        (kargu-config-credential-adapter
         (lambda (_provider _host child) (kargu-async-finish child (kargu-ok "deferred-token")))))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _) (list (list :secret (lambda () (cl-incf called) "private-callable"))))))
      (kargu-test-config-publish (kargu-config-service-context)
                                 '(:providers (("remote-mock" :api "https://mock.example/v1"))) "/fixture" "callable")
      (should-not (kargu-provider-authenticated-p "remote-mock"))
      (should-not (kargu-config-api-key-fast "remote-mock"))
      (should (= called 0))
      (let (result)
        (let ((task (kargu-connection-resolve-async "remote-mock" "m1" :callback (lambda (value) (setq result value)))))
          (should (kargu-async-task-p task))
          (should-not result)
          (should (= called 0))
          (kargu-bridge-test--wait (lambda () result))
          (should (kargu-ok-p result))
          (should (= called 0))
          (kargu-connection-snapshot-wipe (kargu-result-value result)))))))

(ert-deftest kargu-connection-stale-discard-on-config-revision-test ()
  "A real native publication invalidates credentials held at the interop port."
  (let* ((kargu-api-key nil) pending result
         (kargu-config-credential-adapter (lambda (_provider _host child) (setq pending child))))
    (kargu-test-config-publish (kargu-config-service-context)
                               '(:providers (("beta" :api "https://beta.example/v1"))) "/fixture" "first")
    (let ((task (kargu-connection-resolve-async "beta" "m1" :callback (lambda (value) (setq result value)))))
      (kargu-bridge-test--wait (lambda () pending))
      (should-not result)
      (kargu-test-config-invalidate)
      (kargu-async-finish pending (kargu-ok "late-secret"))
      (kargu-bridge-test--wait (lambda () result))
      (should (kargu-err-p result))
      (should (eq (kargu-result-err-code result) :stale-discard))
      (should-not (kargu-async-task-children task)))))

(ert-deftest kargu-connection-cancellation-cleans-up-worker-test ()
  "Cancelling a native-prepared connection drains only its interop child."
  (let* ((kargu-api-key nil) pending result cleaned
         (kargu-config-credential-adapter
          (lambda (_provider _host child)
            (setq pending child)
            (kargu-async-add-cleanup child (lambda () (setq cleaned t))))))
    (kargu-test-config-publish (kargu-config-service-context)
                               '(:providers (("gamma" :api "https://gamma.example/v1"))) "/fixture" "first")
    (let ((task (kargu-connection-resolve-async "gamma" "m1" :callback (lambda (value) (setq result value)))))
      (kargu-bridge-test--wait (lambda () pending))
      (should-not cleaned)
      (kargu-async-cancel task)
      (should cleaned)
      (kargu-async-finish pending (kargu-ok "late-secret"))
      (should-not result)
      (should-not (kargu-async-task-children task)))))

(ert-deftest kargu-connection-timeout-terminates-cleanly-test ()
  "A real native decision admits interop; expiry drains that hanging child."
  (let (delivered-result child
			 (kargu-api-key nil))
    (kargu-test-config-publish (kargu-config-service-context)
                               '(:providers (("delta" :api "https://delta.invalid/v1"))) "/fixture" "timeout")
    (let* ((kargu-config-credential-adapter (lambda (_provider _host task) (setq child task)))
           (task (kargu-connection-resolve-async
                  "delta" "m1" :timeout 0.2 :callback (lambda (result) (setq delivered-result result)))))
      (kargu-bridge-test--wait (lambda () child))
      (kargu-bridge-test--wait (lambda () delivered-result))
      (should (kargu-err-p delivered-result))
      (should-not (kargu-async-pending-p child))
      (should-not (kargu-async-task-children task))
      (should-not (kargu-async-task-timer task)))))

(ert-deftest kargu-connection-retry-preserves-snapshot-test ()
  "A connection snapshot remains immutable across retries even if global config changes."
  (let* ((scope (kargu-credential-scope--create :raw-secret "retry-secret"))
         (snap (kargu-connection-snapshot--create
                :provider "openai"
                :model "gpt-4o"
                :endpoint "https://api.openai.com/v1"
                :config-revision 1
                :credential-scope scope)))
    (should (= (kargu-connection-snapshot-config-revision snap) 1))
    ;; Bump global configuration
    (let ((before (kargu-config-revision)))
      (kargu-test-config-invalidate)
      (should (> (kargu-config-revision) before)))
    ;; Snapshot retained its bound revision and target
    (should (= (kargu-connection-snapshot-config-revision snap) 1))
    (should (equal (kargu-connection-snapshot-endpoint snap) "https://api.openai.com/v1"))
    (should (equal (kargu-connection-snapshot-secret snap) "retry-secret"))))

(ert-deftest kargu-connection-invalid-endpoint-rejected-test ()
  "Native endpoint parsing rejects malformed config before any interop lookup."
  (kargu-test-config-publish (kargu-config-service-context)
                             '(:providers (("bad-prov" :api "invalid://not-http"))) "/fixture" "bad-endpoint")
  (let ((kargu-config-credential-adapter (lambda (&rest _) (ert-fail "No invalid-target interop"))))
    (let ((result (kargu-test-await (lambda (done) (kargu-connection-resolve-async "bad-prov" "m1" :callback done)))))
      (should (kargu-err-p result))
      (should (eq (kargu-result-err-code result) :invalid-arguments)))))

(ert-deftest kargu-connection-worker-never-passes-secrets-in-argv-test ()
  "Worker command invocation arguments must never contain secret tokens."
  (let* ((dummy-task (kargu-async-start (lambda (&rest _) nil)))
         spawned-command
         (kargu-config-worker-runner-fn nil)
         (auth-sources '("/tmp/plain-authinfo")))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq spawned-command (plist-get args :command))
                 (let ((dummy-proc (make-pipe-process :name "test-dummy" :noquery t)))
                   dummy-proc))))
      (kargu-config-worker-resolve "test-prov" "api.example.com" dummy-task)
      (should (listp spawned-command))
      (let ((argv-str (mapconcat #'identity spawned-command " ")))
        ;; Verify host is present in argv (non-secret domain)
        (should (string-search "api.example.com" argv-str))
        ;; Verify batch mode flags
        (should (string-search "-Q" argv-str))
        (should (string-search "--batch" argv-str))
        ;; Verify secret placeholder or sensitive tokens are not in argv
        (should-not (string-search "Bearer" argv-str))
        (should-not (string-search "sk-" argv-str))
        (should-not (string-search "password" argv-str))))
    (kargu-async-cancel dummy-task)))

(provide 'tests/test-connection-snapshot)

;;; test-connection-snapshot.el ends here
