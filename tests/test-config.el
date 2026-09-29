;;; tests/test-config.el --- Tests for the TOML config reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'kargu/config)

(ert-deftest kargu-toml-provider-section-names-test ()
  "Digit-first and quoted provider names are sections, not skipped tables."
  (let ((file (make-temp-file "kargu-toml" nil ".toml")))
    (unwind-protect
        (progn
          (write-region "[providers.302ai]\napi = \"https://a.example/v1\"\n\n[providers.\"my.proxy\"] # local\napi = \"http://localhost:1\"\nmodels = [\"m1\"]\n\n[other]\napi = \"ignored\"\n" nil file)
          (let ((providers (plist-get (kargu--read-toml-config file) :providers)))
            (should (equal (plist-get (cdr (assoc "302ai" providers)) :api) "https://a.example/v1"))
            (should (equal (plist-get (cdr (assoc "my.proxy" providers)) :models) '("m1")))
            (should (= (length providers) 2))))
      (delete-file file))))

(ert-deftest kargu-api-key-resolution-order-test ()
  "An empty TOML key means keyless, ${VAR} expands, and the global key stays with the active provider."
  (let ((kargu--session-provider "alpha")
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

(provide 'tests/test-config)
;;; test-config.el ends here
