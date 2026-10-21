;;; tests/test-config.el --- Tests for the TOML config reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/config)

(defvar kargu-diff-review-mode)

(ert-deftest kargu-config-review-mode-applies-on-reload-test ()
  "TOML parsing refreshes review mode even after the diff module was loaded."
  (let ((file (make-temp-file "kargu-review-config-" nil ".toml"))
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (dolist (mode '("blocking" "async" "auto"))
            (write-region (format "review_mode = %S\n" mode) nil file)
            (kargu--read-toml-config file)
            (should (eq kargu-diff-review-mode (intern mode))))
          (cl-letf (((symbol-function 'kargu--config-plist)
                     (lambda () '(:review-mode 42))))
            (load "kargu/tools/diff" nil t)
            (should (eq kargu-diff-review-mode 'auto))))
      (delete-file file))))

(ert-deftest kargu-config-missing-environment-reference-is-actionable-test ()
  "Missing references warn by name without exposing credential text or matches."
  (let ((process-environment (cons "KARGU_ENV_TEST_SECRET=ok" process-environment)) notices)
    (setenv "KARGU_ENV_TEST_ABSENT" nil)
    (cl-letf (((symbol-function 'kargu-log)
               (lambda (level format &rest arguments)
                 (push (cons level (apply #'format format arguments)) notices))))
      (string-match "keep" "keep")
      (let ((match (match-data)))
        (should (equal (kargu--expand-env-refs "prefix-${KARGU_ENV_TEST_SECRET}-suffix")
                       "prefix-ok-suffix"))
        (should-not (kargu--expand-env-refs "private-literal-${KARGU_ENV_TEST_ABSENT}"))
        (should (equal (match-data) match)))
      (should (= (length notices) 1))
      (should (eq (caar notices) 'warn))
      (should (string-search "KARGU_ENV_TEST_ABSENT" (cdar notices)))
      (should-not (string-search "private-literal" (cdar notices))))))

(ert-deftest kargu-setup-reports-all-mandatory-dependencies-test ()
  "CLI and package failures appear together; optional integrations do not block."
  (let ((problems (car (kargu--setup-problems
                       "real-key" '((:type "CLI" :name "curl" :purpose "HTTP" :install-hint "install curl"))
                       '((plz . "HTTP client"))))))
    (should (= (length problems) 2))
    (should (seq-some (lambda (text) (string-search "curl" text)) problems))
    (should (seq-some (lambda (text) (string-search "plz" text)) problems)))
  (should-not (assq 'eglot kargu--dependencies))
  (should-not (assq 'dape kargu--dependencies)))

(ert-deftest kargu-toml-provider-section-names-test ()
  "Digit-first and quoted provider names are sections, not skipped tables."
  (let ((file (make-temp-file "kargu-toml" nil ".toml")))
    (unwind-protect
        (progn
          (write-region "[providers.302ai]\napi = \"https://a.example/v1\"\n\n[providers.\"my.proxy\"] # local\napi = \"http://localhost:1\"\nmodels = [\"m1\"]\n" nil file)
          (let ((providers (plist-get (kargu--read-toml-config file) :providers)))
            (should (equal (plist-get (cdr (assoc "302ai" providers)) :api) "https://a.example/v1"))
            (should (equal (plist-get (cdr (assoc "my.proxy" providers)) :models) '("m1")))
            (should (= (length providers) 2))))
      (delete-file file))))

(ert-deftest kargu-config-toml-rejects-unsupported-or-malformed-input-test ()
  "Invalid TOML never silently publishes a partial configuration."
  (let ((file (make-temp-file "kargu-invalid-toml-" nil ".toml"))
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (dolist (invalid '("[other]\nx = \"ignored\"\n"
                           "model = 100\n" "provider = true\n"
                           "model = { id = \"m\" }\n"
                           "model = \"\"\"multiline\"\"\"\n"
                           "model = \"m\" garbage\n"
                           "model = \"unterminated\n"
                           "model = \"bad\\q\"\n"
                           "model = \"bad\\uD800\"\n"
                           "model = \"a\"\nmodel = \"b\"\n"
                           "review_mode = \"unknown\"\n"
                           "[provider.a]\nmodels = [\"a\" \"b\"]\n"
                           "[provider.a]\nmodels = [\"a\", 2]\n"
                           "[provider.a]\nmodels = [\"a\"\n"
                           "[provider.a]\nunknown = \"secret-value\"\n"
                           "[provider.a]\n[providers.a]\n"))
          (write-region (concat "review_mode = \"blocking\"\n" invalid) nil file)
          (let ((message (error-message-string (should-error (kargu--read-toml-config file)))))
            (should (string-search file message))
            (should (string-match-p ":[0-9]+:" message))
            (should-not (string-search "secret-value" message)))
          (should (eq kargu-diff-review-mode 'auto)))
      (delete-file file))))

(ert-deftest kargu-config-toml-arrays-and-strings-respect-quoting-test ()
  "Comments, bracket characters and supported escapes retain their meaning."
  (let ((file (make-temp-file "kargu-valid-toml-" nil ".toml")))
    (unwind-protect
        (progn
          (write-region
           "provider = 'a' # comment\n[providers.a]\napikey = 'literal#value'\nmodels = [\n  \"a]#b\", # not the end\n  '\\literal',\n  \"\\u00e7\\U0001F642\",\n]\n"
           nil file)
          (let ((provider (cdar (plist-get (kargu--read-toml-config file) :providers))))
            (should (equal (plist-get provider :apikey) "literal#value"))
            (should (equal (plist-get provider :models) '("a]#b" "\\literal" "ç🙂")))))
      (delete-file file))))

(ert-deftest kargu-config-invalid-reload-keeps-cache-unpublished-test ()
  "A malformed reload raises instead of publishing a partial cache or mode."
  (let ((file (make-temp-file "kargu-atomic-config-" nil ".toml"))
        (kargu--config-cache nil) (kargu--config-cache-path nil)
        (kargu--config-mtime nil) (kargu-diff-review-mode 'auto))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-config-file) (lambda () file)))
          (write-region "provider = \"stable\"\nreview_mode = \"auto\"\n" nil file)
          (let ((before (kargu--config-plist)) (mtime kargu--config-mtime))
            (write-region "review_mode = \"blocking\"\nmodel = 42\n" nil file)
            (set-file-times file (time-add mtime 2))
            (should-error (kargu--config-plist))
            (should (eq kargu--config-cache before))
            (should (equal kargu--config-mtime mtime))
            (should (eq kargu-diff-review-mode 'auto))
            (should-error (kargu--config-plist))))
      (delete-file file))))

(ert-deftest kargu-api-key-resolution-order-test ()
  "An empty TOML key means keyless, ${VAR} expands, and the global key stays with the active provider."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "alpha"))
        (kargu-api-key nil))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("alpha" :apikey "${KARGU_TEST_KEY}")
                            ("beta" :apikey "")
                            ("gamma"))))
              ((symbol-function 'kargu-provider-env) (lambda (_p) '("KARGU_TEST_ENV"))))
      (setenv "KARGU_TEST_KEY" "from-ref")
      (setenv "KARGU_TEST_ENV" "from-env")
      (unwind-protect
          (progn
            (should (equal (kargu--resolve-api-key "alpha") "from-ref"))
            (should (equal (kargu--resolve-api-key "beta") ""))
            (should (equal (kargu--resolve-api-key "gamma") "from-env"))
            (setenv "KARGU_TEST_KEY" nil)
            (should (equal (kargu--resolve-api-key "alpha") "from-env"))
            (let ((kargu-api-key "global"))
              (should (equal (kargu--resolve-api-key "alpha") "global"))
              (should (equal (kargu--resolve-api-key "gamma") "from-env"))))
        (setenv "KARGU_TEST_KEY" nil)
        (setenv "KARGU_TEST_ENV" nil)))))

(ert-deftest kargu-provider-detection-respects-credential-owner-test ()
  "Only the active provider can use the global credential override."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "alpha"))
        (kargu-api-key "active-only")
        (process-environment (copy-sequence process-environment)))
    (setenv "KARGU_ABSENT_PROVIDER_KEY" nil)
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("alpha") ("beta" :apikey "${KARGU_ABSENT_PROVIDER_KEY}"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil))
              ((symbol-function 'kargu--auth-source-api-key) (lambda (_) nil)))
      (should (kargu-provider-authenticated-p "alpha"))
      (should-not (kargu-provider-authenticated-p "beta"))
      (should-not (kargu--resolve-api-key "beta")))))

(ert-deftest kargu-provider-discovery-never-invokes-secret-function-or-gpg-test ()
  "Provider discovery never calls auth-source `:secret' functions or unlocks GPG."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "alpha"))
        (kargu-api-key nil)
        (auth-sources '("~/.authinfo.gpg" "secrets:Login" macos-keychain-internet))
        (secret-called nil)
        (searched-sources nil))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("alpha" :apikey "configured-key")
                            ("beta" :api "https://beta.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil))
              ((symbol-function 'auth-source-search)
               (lambda (&rest _)
                 (setq searched-sources auth-sources)
                 (list (list :host "beta.example"
                             :secret (lambda ()
                                       (setq secret-called t)
                                       "unlocked-secret"))))))
      (should (kargu-provider-authenticated-p "alpha"))
      (should-not (kargu-provider-authenticated-p "beta"))
      (should-not secret-called)
      (should-not searched-sources))))

(ert-deftest kargu-config-resolve-api-key-async-cancel-and-unavailable-backend-test ()
  "Explicit key resolution reports unavailable backends and supports async cancel."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "beta"))
        (kargu-api-key nil)
        (auth-sources '("~/.authinfo.gpg" macos-keychain-internet)))
    (cl-letf (((symbol-function 'kargu--config-providers)
               (lambda () '(("beta" :api "https://beta.example/v1"))))
              ((symbol-function 'kargu-provider-keyless-p) (lambda (_) nil))
              ((symbol-function 'kargu-provider-env) (lambda (_) nil)))
      (let ((res (kargu-config-resolve-api-key-result "beta")))
        (should (kargu-err-p res))
        (should (eq (kargu-result-err-code res) 'unavailable)))
      ;; Async adapter cancellation and owner validation
      (let* (pending-task delivered canceled-adapter
             (kargu-config-credential-adapter
              (lambda (_provider _host task)
                (setq pending-task task)
                (kargu-async-add-cleanup
                 task (lambda () (setq canceled-adapter t))))))
        (let ((task (kargu-config-resolve-api-key-async
                     "beta" (lambda (r) (setq delivered r)))))
          (kargu-async-cancel task)
          (should canceled-adapter)
          (kargu-async-finish pending-task (kargu-ok "late-secret"))
          (should-not delivered))))))

(provide 'tests/test-config)
;;; test-config.el ends here
