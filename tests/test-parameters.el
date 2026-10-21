;;; test-parameters.el --- Native request parameter policy tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; All policy tests are offline and independent of a particular model name.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/api/parameters)
(require 'kargu/api/request)

(ert-deftest kargu-parameters-unknown-models-use-provider-policy-test ()
  "Catalog defaults send one cap, with conservative OpenAI sampling."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (should (equal (kargu-api-request-parameters :model "unknown" :provider "openai"
                                                :temperature 0.2 :max-tokens 1234)
                   '(("max_completion_tokens" . 1234))))
    (should (equal (kargu-api-request-parameters :model "unknown" :provider "openrouter"
                                                :temperature 0 :max-tokens 1234)
                   '(("temperature" . 0) ("max_tokens" . 1234))))
    (should-not (kargu-api-request-parameters :model "unknown" :provider "openai"))))

(ert-deftest kargu-parameters-metadata-overrides-names-and-defaults-test ()
  "Declared support, not model names, controls cap aliases and sampling."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "unexpected-id"
                              '(("supported_parameters" . ["max_completion_tokens"])) "openrouter")
    (should (equal (kargu-api-request-parameters :model "unexpected-id" :provider "openrouter"
                                                :temperature 0.2 :max-tokens 500)
                   '(("max_completion_tokens" . 500))))
    (kargu-model-set-metadata "unexpected-id"
                              '(("supported_parameters" . ["max_tokens" "temperature"])) "openai")
    (should (equal (kargu-api-request-parameters :model "unexpected-id" :provider "openai"
                                                :temperature 0.4 :max-tokens 600)
                   '(("temperature" . 0.4) ("max_tokens" . 600))))))

(ert-deftest kargu-parameters-both-aliases-still-select-one-test ()
  "When both aliases are accepted, the provider's preferred field wins."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (dolist (provider '("openai" "openrouter" "anthropic"))
      (kargu-model-set-metadata "both"
                                '(("supported_parameters" . ["max_tokens" "max_completion_tokens"]))
                                provider)
      (let ((fields (kargu-api-request-parameters :model "both" :provider provider :max-tokens 123)))
        (should (= (length fields) 1))
        (should (= (cdar fields) 123))
        (should (equal (caar fields) (if (equal provider "openai")
                                        "max_completion_tokens" "max_tokens")))))))

(ert-deftest kargu-parameters-no-supported-cap-refuses-explicit-limit-test ()
  "An explicit cost/output cap is never silently discarded."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "uncapped" '(("supported_parameters" . ["temperature" "tools"])) "openrouter")
    (should-error (kargu-api-request-parameters :model "uncapped" :provider "openrouter"
                                              :max-tokens 100) :type 'user-error)
    (should (equal (kargu-api-request-parameters :model "uncapped" :provider "openrouter"
                                                :temperature 0.3)
                   '(("temperature" . 0.3))))))

(ert-deftest kargu-parameters-empty-metadata-remains-unknown-test ()
  "Empty advertised parameter lists preserve the existing unknown contract."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "empty" '(("supported_parameters" . [])) "openai")
    (should (equal (kargu-api-request-parameters :model "empty" :provider "openai"
                                                :temperature 0.2 :max-tokens 10)
                   '(("max_completion_tokens" . 10))))))

(ert-deftest kargu-parameters-do-not-borrow-other-provider-or-fuzzy-alias-test ()
  "A foreign or fuzzy metadata record cannot decide request parameter support."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "same-id"
                              '(("provider" . "unrelated")
                                ("supported_parameters" . ["max_completion_tokens"])))
    (kargu-model-set-metadata "vendor/alias"
                              '(("supported_parameters" . ["max_completion_tokens"])))
    (dolist (model '("same-id" "alias"))
      (should (equal (kargu-api-request-parameters :model model :provider "openrouter"
                                                  :temperature 0.2 :max-tokens 10)
                     '(("temperature" . 0.2) ("max_tokens" . 10)))))))

(ert-deftest kargu-parameters-provider-overrides-preserve-explicit-nil-test ()
  "A provider policy can disable sampling without changing its shared format."
  (let ((kargu-providers--table (copy-hash-table kargu-providers--table))
        (kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-register-provider :id "test-parameters" :format 'openapi
                             :request '(:max-output-key "max_completion_tokens"
                                        :sampling-parameters nil))
    (should (equal (kargu-api-request-parameters :model "unknown" :provider "test-parameters"
                                                :temperature 0.2 :max-tokens 42)
                   '(("max_completion_tokens" . 42))))
    (should (member "temperature" (plist-get (kargu-provider-request-policy "openrouter")
                                              :sampling-parameters)))))

(ert-deftest kargu-parameters-invalid-values-refused-test ()
  "Malformed settings fail before transport instead of causing provider errors."
  (dolist (cap '(0 -1 2.5 "100"))
    (should-error (kargu-api-request-parameters :provider "openai" :max-tokens cap)
                  :type 'user-error))
  (should-error (kargu-api-request-parameters :provider "openai" :temperature "0.2")
                :type 'user-error)
  (let ((kargu-providers--table (copy-hash-table kargu-providers--table)))
    (kargu-register-provider :id "bad-parameters" :request '(:max-output-key "typo"))
    (should-error (kargu-api-request-parameters :provider "bad-parameters" :max-tokens 10)
                  :type 'user-error)))

(ert-deftest kargu-parameters-extra-fields-cannot-reintroduce-cap-conflict-test ()
  "Even explicit payload extras cannot cause both cap aliases to be posted."
  (let ((kargu-max-tokens 100) (kargu-session--context
                                (kargu-test-session-with-history :provider "openai"))
        (kargu--model-metadata-table (make-hash-table :test #'equal)))
    (should-error (kargu--build-payload '("max_tokens" . 200)) :type 'user-error)))

(provide 'tests/test-parameters)
;;; test-parameters.el ends here
