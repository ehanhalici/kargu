;;; test-parameters.el --- Native request parameter policy tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; All policy tests are offline and independent of a particular model name.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'kargu/api/request)

;; Pure cap/sampling/reasoning policy cases moved to api_policy.rs.  These
;; tests retain editor capture and provider/alias isolation contracts.

(ert-deftest kargu-parameters-capture-exact-model-metadata-without-fuzzy-borrow-test ()
  "A foreign provider or short alias never controls captured request policy."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "same" '(("supported_parameters" . ["max_completion_tokens"])) "other")
    (kargu-model-set-metadata "vendor/alias" '(("supported_parameters" . ["max_completion_tokens"])) "openrouter")
    (dolist (model '("same" "alias"))
      (should (eq (kargu-aget (kargu-api-request-tuning "openrouter" model) "supported_parameters") :json-null)))
    (should (equal (kargu-aget (kargu-api-request-tuning "other" "same") "supported_parameters") ["max_completion_tokens"]))))

(ert-deftest kargu-parameters-capture-explicit-nil-and-invalid-values-without-policy-test ()
  "Core gets the exact intent; invalid DTOs are rejected before native HTTP."
  (let ((kargu-providers--table (copy-hash-table kargu-providers--table))
        (kargu-temperature "invalid") (kargu-max-tokens 0))
    (kargu-register-provider :id "fixture" :request '(:max-output-key "max_completion_tokens" :sampling-parameters nil))
    (let ((tuning (kargu-api-request-tuning "fixture" "unknown")))
      (should (equal (kargu-aget tuning "temperature") "invalid"))
      (should (= (kargu-aget tuning "max_tokens") 0))
      (should (plist-member (kargu-aget tuning "provider_policy") :sampling-parameters))
      (should-not (plist-get (kargu-aget tuning "provider_policy") :sampling-parameters)))))

(ert-deftest kargu-parameters-bound-connection-freezes-intent-test ()
  "Later preference/metadata updates cannot change a captured connection."
  (let* ((kargu-temperature 0.2) (kargu-max-tokens 100)
         (settings (kargu-api-connection-settings "openai" "unknown"))
         (snapshot (kargu-connection-snapshot--create :provider "openai" :model "unknown" :settings settings)))
    (let ((kargu-temperature 1.0) (kargu-max-tokens 200))
      (kargu-connection-call
       snapshot (lambda ()
                  (let ((tuning (kargu-api-request-tuning "openai" "unknown")))
                    (should (= (kargu-aget tuning "temperature") 0.2))
                    (should (= (kargu-aget tuning "max_tokens") 100))))))))

(provide 'tests/test-parameters)
;;; test-parameters.el ends here
