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
    (should-error (setf (kargu-connection-snapshot-provider snap) "mutated"))
    (should-error (setf (kargu-connection-snapshot-endpoint snap) "https://mutated.com"))
    (should-error (setf (kargu-connection-snapshot-config-revision snap) 99))))

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
  "Keyless providers resolve immediately without auth sources or network."
  (let* ((kargu-session--context
          (kargu-test-session-with-history :provider "ollama" :model "llama3"))
         delivered-result)
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("ollama" :api "http://localhost:11434/v1" :keyless t)))))
      (let ((task (kargu-connection-resolve-async
                   "ollama" "llama3"
                   :callback (lambda (res) (setq delivered-result res)))))
        (should (kargu-async-task-p task))
        (should delivered-result)
        (should (kargu-ok-p delivered-result))
        (let ((snap (kargu-result-value delivered-result)))
          (should (kargu-connection-snapshot-p snap))
          (should (equal (kargu-connection-snapshot-provider snap) "ollama"))
          (should (equal (kargu-connection-snapshot-endpoint snap) "http://localhost:11434/v1"))
          (should (equal (kargu-connection-snapshot-secret snap) "")))))))

(ert-deftest kargu-connection-callable-secret-never-called-on-ui-thread-test ()
  "Callable secrets must NEVER be invoked synchronously on UI thread (CONFIG-01)."
  (let* ((called-count 0)
         (secret-fn (lambda ()
                      (setq called-count (1+ called-count))
                      "secret-from-callable"))
         (auth-sources '("~/.authinfo"))
         (kargu-session--context
          (kargu-test-session-with-history :provider "remote-mock" :model "m1")))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("remote-mock" :api "https://mock.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil))
              ((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 (list (list :host "mock.example" :secret secret-fn)))))
      ;; 1. Discovery safety: checking authentication must not call secret function
      (should-not (kargu-provider-authenticated-p "remote-mock"))
      (should (= called-count 0))

      ;; 2. UI safety: setup check must not call secret function
      (let ((report (kargu--setup-problems (kargu-config-api-key-fast "remote-mock") nil nil)))
        (should (listp report))
        (should (= called-count 0)))

      ;; 3. Synchronous result resolution must refuse callable secret functions
      (let ((res (kargu-config-resolve-api-key-result "remote-mock")))
        (should (kargu-err-p res))
        (should (eq (kargu-result-err-code res) 'unavailable))
        (should (= called-count 0)))

      ;; 4. Asynchronous connection resolution must return task immediately without calling secret on UI thread
      (let* (async-delivered
             (kargu-config-credential-adapter
              (lambda (_prov _host adapter-task)
                ;; Adapter receives task without calling secret on initial invocation
                (kargu-async-finish adapter-task (kargu-ok "deferred-token")))))
        (let ((task (kargu-connection-resolve-async
                     "remote-mock" "m1"
                     :callback (lambda (r) (setq async-delivered r)))))
          (should (kargu-async-task-p task))
          ;; Callable secret was NEVER called on UI thread
          (should (= called-count 0))
          (should async-delivered)
          (should (kargu-ok-p async-delivered)))))))

(ert-deftest kargu-connection-stale-discard-on-config-revision-test ()
  "Late discovery results after config revision changes must be discarded."
  (let* ((kargu-session--context
          (kargu-test-session-with-history :provider "beta" :model "m1"))
         delivered-result
         pending-adapter-task
         (kargu-config-credential-adapter
          (lambda (_prov _host task)
            (setq pending-adapter-task task))))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("beta" :api "https://beta.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil)))
      (let ((task (kargu-connection-resolve-async
                   "beta" "m1"
                   :callback (lambda (r) (setq delivered-result r)))))
        (should (kargu-async-task-p task))
        (should pending-adapter-task)
        (should-not delivered-result)
        ;; Config revision bumps while discovery was in flight:
        (kargu-config-bump-revision)
        ;; Adapter now finishes with late result:
        (kargu-async-finish pending-adapter-task (kargu-ok "late-secret-token"))
        ;; Result must be rejected as stale!
        (should delivered-result)
        (should (kargu-err-p delivered-result))
        (should (eq (kargu-result-err-code delivered-result) :stale-discard))))))

(ert-deftest kargu-connection-cancellation-cleans-up-worker-test ()
  "Cancelling resolution terminates background worker and avoids delivering result."
  (let* ((kargu-session--context
          (kargu-test-session-with-history :provider "gamma" :model "m1"))
         delivered-result
         cleanup-invoked-p
         pending-adapter-task
         (kargu-config-credential-adapter
          (lambda (_prov _host task)
            (setq pending-adapter-task task)
            (kargu-async-add-cleanup
             task (lambda () (setq cleanup-invoked-p t))))))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("gamma" :api "https://gamma.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil)))
      (let ((task (kargu-connection-resolve-async
                   "gamma" "m1"
                   :callback (lambda (r) (setq delivered-result r)))))
        (should (kargu-async-task-p task))
        (should-not cleanup-invoked-p)
        ;; Cancel the resolution task:
        (kargu-async-cancel task)
        (should cleanup-invoked-p)
        ;; Late delivery after cancellation must be ignored:
        (kargu-async-finish pending-adapter-task (kargu-ok "late-value"))
        (should-not delivered-result)))))

(ert-deftest kargu-connection-timeout-terminates-cleanly-test ()
  "Hanging worker is timed out and task completes with auth-unavailable."
  (let* ((kargu-session--context
          (kargu-test-session-with-history :provider "delta" :model "m1"))
         delivered-result
         (kargu-config-credential-adapter
          (lambda (_prov _host _task)
            ;; Intentionally do nothing: simulate hanging worker
            nil)))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("delta" :api "https://delta.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil)))
      (let ((task (kargu-connection-resolve-async
                   "delta" "m1"
                   :timeout 0.05
                   :callback (lambda (r) (setq delivered-result r)))))
        (should (kargu-async-task-p task))
        ;; Wait for timeout
        (sleep-for 0.1)
        (should delivered-result)
        (should (kargu-err-p delivered-result))))))

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
      (kargu-config-bump-revision)
      (should (> (kargu-config-revision) before)))
    ;; Snapshot retained its bound revision and target
    (should (= (kargu-connection-snapshot-config-revision snap) 1))
    (should (equal (kargu-connection-snapshot-endpoint snap) "https://api.openai.com/v1"))
    (should (equal (kargu-connection-snapshot-secret snap) "retry-secret"))))

(ert-deftest kargu-connection-invalid-endpoint-rejected-test ()
  "Malformed endpoint URLs must be rejected with typed :invalid-arguments error."
  (let* ((kargu-session--context
          (kargu-test-session-with-history :provider "bad-prov" :model "m1"))
         delivered-result)
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("bad-prov" :api "invalid://not-http"))))
              ((symbol-function 'kargu--api-base) (lambda (&rest _) "invalid://not-http")))
      (let ((task (kargu-connection-resolve-async
                   "bad-prov" "m1"
                   :callback (lambda (r) (setq delivered-result r)))))
        (should (kargu-async-task-p task))
        (should delivered-result)
        (should (kargu-err-p delivered-result))
        (should (eq (kargu-result-err-code delivered-result) :invalid-arguments))))))

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
