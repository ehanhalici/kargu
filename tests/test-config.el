;;; tests/test-config.el --- Tests for the TOML config reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/config)

(defvar kargu-diff-review-mode)

(ert-deftest kargu-config-review-mode-applies-on-reload-test ()
  "Only validated publication changes review mode; parsing stays pure."
  (let ((file (make-temp-file "kargu-review-config-" nil ".toml"))
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (dolist (mode '("blocking" "async" "auto"))
            (write-region (format "review_mode = %S\n" mode) nil file)
            (let ((data (kargu--read-toml-config file)))
              (kargu-config-publish (kargu-config-service-create) data file mode))
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
  "A malformed async reload retains the last publication and mode."
  (let ((file (make-temp-file "kargu-atomic-config-" nil ".toml"))
        (kargu-application--bound (kargu-application-create))
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (write-region "provider = \"stable\"\nreview_mode = \"auto\"\n" nil file)
          (should (kargu-ok-p (kargu-test-await
                              (lambda (done) (kargu-config-refresh-async done :paths (list file))))))
          (let ((before (kargu--config-plist)))
            (write-region "review_mode = \"blocking\"\nmodel = 42\n" nil file)
            (should (kargu-err-p (kargu-test-await
                                 (lambda (done) (kargu-config-refresh-async done :paths (list file))))))
            (should (eq (kargu--config-plist) before))
            (should (eq kargu-diff-review-mode 'auto))))
      (delete-file file))))

(ert-deftest kargu-config-refresh-detects-content-deletion-and-owner-test ()
  "Refresh detects same-mtime changes and deletion without mixing owners."
  (let ((file (make-temp-file "kargu-config-owner-" nil ".toml"))
        (kargu-application--bound (kargu-application-create)))
    (unwind-protect
        (progn
          (write-region "provider = \"alpha\"\n" nil file)
          (let* ((stamp (file-attribute-modification-time (file-attributes file)))
                 (refresh (lambda () (kargu-test-await
                                      (lambda (done)
                                        (kargu-config-refresh-async done :paths (list file)))))))
            (should (kargu-ok-p (funcall refresh)))
            (let ((revision (kargu-config-revision)))
              (write-region "provider = \"bravo\"\n" nil file)
              (set-file-times file stamp)
              (should (kargu-ok-p (funcall refresh)))
              (should (> (kargu-config-revision) revision))
              (should (equal (plist-get (kargu--config-plist) :provider) "bravo")))
            (let ((kargu-application--bound (kargu-application-create)))
              (should-not (kargu--config-plist)))
            (delete-file file)
            (should (kargu-ok-p (funcall refresh)))
            (should-not (kargu--config-plist))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest kargu-config-hot-readers-never-touch-files-test ()
  "Config, endpoint and fast credential readers only consume memory."
  (let ((kargu-application--bound (kargu-application-create))
        (native-comp-enable-subr-trampolines nil)
        (kargu-api-key nil))
    (kargu-config-publish (kargu-config-service-context)
                         '(:provider "alpha" :providers (("alpha" :apikey "" :api "http://a/v1")))
                         "/nonexistent/config" "digest")
    (cl-letf (((symbol-function 'file-readable-p) (lambda (&rest _) (ert-fail "UI file read")))
              ((symbol-function 'file-attributes) (lambda (&rest _) (ert-fail "UI stat")))
              ((symbol-function 'file-exists-p) (lambda (&rest _) (ert-fail "UI exists"))))
      (should (kargu--config-plist))
      (should (equal (kargu--api-base "alpha") "http://a/v1"))
      (should (equal (kargu-config-api-key-fast "alpha") "")))))

(ert-deftest kargu-config-refresh-reverse-completion-and-cancel-test ()
  "Only the newest refresh publishes; cancellation closes its worker task."
  (let ((kargu-application--bound (kargu-application-create)) tasks results cleaned)
    (cl-letf (((symbol-function 'kargu-config-worker-start)
               (lambda (task &rest _)
                 (push task tasks)
                 (kargu-async-add-cleanup task (lambda () (push task cleaned))))))
      (let* ((first (kargu-config-refresh-async (lambda (result) (push result results))))
             (second (kargu-config-refresh-async (lambda (result) (push result results))))
             (value (kargu-ok '(:data (:provider "new") :path "/fake" :digest "new"))))
        (kargu-async-finish second value)
        (kargu-async-finish first (kargu-ok '(:data (:provider "old") :path "/fake" :digest "old")))
        (should (kargu-err-p (car results)))
        (should (equal (plist-get (kargu--config-plist) :provider) "new"))
        (let ((third (kargu-config-refresh-async #'ignore)))
          (kargu-async-cancel third)
          (should (memq third cleaned)))))))

(ert-deftest kargu-config-snapshot-detaches-and-hides-credentials-test ()
  "Published data cannot be mutated through input or public snapshot reads."
  (let* ((key (copy-sequence "synthetic-config-secret"))
         (data (list :providers (list (list "alpha" :apikey key))))
         (snapshot (kargu-config-snapshot-create :data data)))
    (should-not (string-search key (prin1-to-string snapshot)))
    (aset key 0 ?X)
    (let ((copy (kargu-config-snapshot-data snapshot)))
      (aset (plist-get (cdar (plist-get copy :providers)) :apikey) 0 ?Y))
    (should (equal (plist-get (cdar (plist-get (kargu-config-snapshot-data snapshot)
                                             :providers)) :apikey)
                   "synthetic-config-secret"))))

(ert-deftest kargu-config-worker-yields-and-cancellation-kills-child-test ()
  "A genuinely slow child leaves timers responsive and dies on cancellation."
  (let* ((ticks 0) (task (kargu-async-start #'ignore :owner nil :parent nil))
         (timer (run-at-time 0.01 0.01 (lambda () (cl-incf ticks)))) process)
    (unwind-protect
        (progn
          (kargu-config-worker-start task "(sleep-for 10)" nil :name "test-slow")
          (setq process (get-process "kargu-test-slow-worker"))
          (should (process-live-p process))
          (let ((deadline (+ (float-time) 0.1)))
            (while (< (float-time) deadline) (accept-process-output nil 0.01)))
          (should (> ticks 1))
          (kargu-async-cancel task)
          (should-not (process-live-p process))
          (should-not (buffer-live-p (process-buffer process))))
      (cancel-timer timer)
      (kargu-async-cancel task))))

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
