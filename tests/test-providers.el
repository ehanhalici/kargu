;;; tests/test-providers.el --- Tests for Provider Registry & Zero-URL Config -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests for `kargu/providers', built-in catalog lookups,
;; automatic endpoint resolution without specifying `api' in TOML,
;; user URL overrides, and provider-specific environment key resolution.

;;; Code:

(require 'tests/test-helpers)
(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/providers)
(require 'kargu/config)
(require 'kargu/history)
(require 'kargu/api/http)
(require 'kargu/chat/tune)

(ert-deftest kargu-providers-catalog-count-test ()
  "Catalog must contain at least 160 registered providers."
  (let ((providers (kargu-provider-list)))
    (should (>= (length providers) 160))
    (should (member "deepseek" providers))
    (should (member "groq" providers))
    (should (member "openai" providers))
    (should (member "anthropic" providers))
    (should (member "openrouter" providers))
    (should (member "ollama" providers))
    (should (member "togetherai" providers))
    (should (member "cerebras" providers))))

(ert-deftest kargu-providers-builtins-endpoints-test ()
  "Built-in providers must have correct default URLs."
  (should (equal (kargu-provider-api "deepseek") "https://api.deepseek.com/v1"))
  (should (equal (kargu-provider-api "groq") "https://api.groq.com/openai/v1"))
  (should (equal (kargu-provider-api "openai") "https://api.openai.com/v1"))
  (should (equal (kargu-provider-api "anthropic") "https://api.anthropic.com/v1"))
  (should (equal (kargu-provider-api "togetherai") "https://api.together.xyz/v1"))
  (should (equal (kargu-provider-api "cerebras") "https://api.cerebras.ai/v1"))
  (should (equal (kargu-provider-api "xai") "https://api.x.ai/v1"))
  (should (equal (kargu-provider-api "mistral") "https://api.mistral.ai/v1"))
  (should (equal (kargu-provider-api "ollama") "http://localhost:11434/v1"))
  (should (equal (kargu-provider-api "openrouter") "https://openrouter.ai/api/v1")))

(ert-deftest kargu-providers-builtins-models-test ()
  "Built-in providers must supply dynamic models API routes without static hardcoding."
  (should (equal (kargu-provider-models-api "deepseek") "https://api.deepseek.com/models"))
  (should (equal (kargu-provider-models-api "groq") "https://api.groq.com/openai/v1/models"))
  (should (equal (kargu-provider-models-api "openai") "https://api.openai.com/v1/models"))
  (should (equal (kargu-provider-models-api "anthropic") "https://api.anthropic.com/v1/models"))
  (should (equal (kargu-provider-models-api "ollama") "http://localhost:11434/api/tags"))
  (should (equal (kargu-provider-models-api "openrouter") "https://openrouter.ai/api/v1/models")))

(ert-deftest kargu-providers-zero-url-toml-config-test ()
  "When TOML specifies only `apikey', URL is automatically resolved."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu-application--bound (kargu-application-create))
         (kargu-session--context
          (kargu-test-session-with-history :provider nil :model nil)))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"deepseek\"\n\n"
                    "[providers.deepseek]\n"
                    "apikey = \"sk-test-deepseek-12345\"\n"
                    "model = \"deepseek-chat\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
            (should (kargu-ok-p (kargu-test-await
                                (lambda (done) (kargu-config-refresh-async done :paths (list temp-config))))))
            (should (equal (kargu--provider-name) "deepseek"))
            ;; API base should resolve to DeepSeek's default URL automatically:
            (should (equal (kargu--api-base) "https://api.deepseek.com/v1"))
            ;; Model should resolve from TOML configured model:
            (should (equal (kargu--model) "deepseek-chat"))
            ;; API key should resolve to the configured key:
            (should (equal (kargu--resolve-api-key) "sk-test-deepseek-12345"))))
      (delete-file temp-config))))

(ert-deftest kargu-providers-custom-url-override-test ()
  "When user specifies custom `api' in TOML, it overrides the built-in default."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu-application--bound (kargu-application-create))
         (kargu-session--context
          (kargu-test-session-with-history :provider nil :model nil)))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"deepseek\"\n\n"
                    "[providers.deepseek]\n"
                    "api = \"https://my-custom-proxy.internal/v1\"\n"
                    "apikey = \"sk-test-custom-key\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
            (should (kargu-ok-p (kargu-test-await
                                (lambda (done) (kargu-config-refresh-async done :paths (list temp-config))))))
            (should (equal (kargu--provider-name) "deepseek"))
            ;; User-provided API base must take precedence:
            (should (equal (kargu--api-base) "https://my-custom-proxy.internal/v1"))
            (should (equal (kargu--resolve-api-key) "sk-test-custom-key"))))
      (delete-file temp-config))))

(ert-deftest kargu-providers-env-key-resolution-test ()
  "Environment variable specific to active provider is used if TOML omits apikey."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu-application--bound (kargu-application-create))
         (kargu-session--context
          (kargu-test-session-with-history :provider "groq"))
         (kargu-api-key nil))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"groq\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
            (should (kargu-ok-p (kargu-test-await
                                (lambda (done) (kargu-config-refresh-async done :paths (list temp-config))))))
            (setenv "GROQ_API_KEY" "gsk_test_groq_env_key")
            (unwind-protect
                (progn
                  (should (equal (kargu--provider-name) "groq"))
                  (should (equal (kargu--api-base) "https://api.groq.com/openai/v1"))
                  (should (equal (kargu--resolve-api-key) "gsk_test_groq_env_key")))
              (setenv "GROQ_API_KEY" nil))))
      (delete-file temp-config))))

(ert-deftest kargu-providers-dynamic-registration-test ()
  "Dynamic registration adds new provider with custom defaults."
  (kargu-register-provider
   :id "test-dynamic-ai"
   :name "Test Dynamic AI"
   :api "https://api.test-dynamic.ai/v1"
   :models-api "https://api.test-dynamic.ai/v1/models"
   :env '("TEST_DYNAMIC_API_KEY"))
  (should (equal (kargu-provider-api "test-dynamic-ai") "https://api.test-dynamic.ai/v1"))
  (should (equal (kargu-provider-models-api "test-dynamic-ai") "https://api.test-dynamic.ai/v1/models"))
  (should (equal (kargu-provider-name "test-dynamic-ai") "Test Dynamic AI"))
  (should (member "test-dynamic-ai" (kargu-provider-list))))

(ert-deftest kargu-providers-session-switch-test ()
  "`kargu-set-provider' sets session provider, model from live cache, and resolves correct API base."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider nil :model nil)))
    (puthash "cerebras" '("llama3.1-70b") kargu--live-models-cache)
    (kargu-set-provider "cerebras")
    (should (equal (kargu-selection-provider) "cerebras"))
    (should (equal (kargu--api-base) "https://api.cerebras.ai/v1"))
    (should (equal (kargu-selection-model) "llama3.1-70b"))))

(ert-deftest kargu-providers-generic-catalog-test ()
  "Keyless and local properties are driven by catalog.el and lookup is exact."
  ;; Keyless runners
  (should (kargu-provider-keyless-p "ollama"))
  (should (kargu-provider-keyless-p "lmstudio"))
  (should (kargu-provider-keyless-p "llamacpp"))
  (should (kargu-provider-keyless-p "llama_cpp"))
  (should-not (kargu-provider-keyless-p "openai"))
  (should-not (kargu-provider-keyless-p "deepseek"))

  ;; Local runners
  (should (kargu-provider-local-p "ollama"))
  (should (kargu-provider-local-p "lmstudio"))
  (should (kargu-provider-local-p "llamacpp"))
  (should (kargu-provider-local-p "llama_cpp"))
  (should-not (kargu-provider-local-p "openai"))

  ;; Exact name lookup for both llamacpp and llama_cpp
  (let ((l1 (kargu-provider-get "llamacpp"))
        (l2 (kargu-provider-get "llama_cpp")))
    (should (plist-get l1 :keyless))
    (should (plist-get l2 :keyless))
    (should (equal (plist-get l1 :models-api) "http://127.0.0.1:8080/v1/models"))
    (should (equal (plist-get l2 :models-api) "http://127.0.0.1:8080/v1/models")))

  ;; Verify obsolete hardcoded variables/functions are removed
  (should-not (boundp 'kargu-providers-popular))
  (should-not (fboundp 'kargu-provider-popular-list))
  (should-not (boundp 'kargu-providers-local-keyless))
  (should-not (boundp 'kargu--env-key-by-host))
  (should-not (fboundp 'kargu--env-api-key)))

(ert-deftest kargu-providers-authentication-detection-test ()
  "Keyless local runners and env-configured providers report authenticated."
  ;; Ollama and llama_cpp are keyless local runners
  (should (kargu-provider-authenticated-p "ollama"))
  (should (kargu-provider-authenticated-p "llama_cpp"))
  (should (member "ollama" (kargu-connected-providers)))
  (should (member "llama_cpp" (kargu-connected-providers)))
  ;; Without key, a cloud provider is not authenticated
  (let* ((empty-cfg (make-temp-file "kargu-empty-" nil ".toml"))
         (kargu-application--bound (kargu-application-create))
         (kargu-api-key nil))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-config-file) (lambda () empty-cfg)))
          (setenv "GROQ_API_KEY" nil)
          (should-not (kargu-provider-authenticated-p "groq"))
          ;; When env var is set, it becomes authenticated
          (setenv "GROQ_API_KEY" "gsk_test")
          (should (kargu-provider-authenticated-p "groq"))
          (should (member "groq" (kargu-connected-providers))))
      (setenv "GROQ_API_KEY" nil)
      (when (file-exists-p empty-cfg) (delete-file empty-cfg)))))

(ert-deftest kargu-providers-payload-tuning-test ()
  "Payload stays canonical while core receives raw tuning preferences."
  (let ((kargu-reasoning-effort 'medium) (kargu-thinking-budget 4096)
        (kargu-max-tokens 8192) (kargu-temperature 0.5)
        (kargu-session--context
         (kargu-test-session-with-history :messages '((("role" . "user") ("content" . "hello")))
                                         :provider "deepseek" :model "deepseek-chat")))
    (let ((payload (kargu--build-payload))
          (tuning (kargu-api-request-tuning "deepseek" "deepseek-chat")))
      (should (equal (kargu-aget payload "model") "deepseek-chat"))
      (should-not (assoc "temperature" payload))
      (should-not (assoc "max_tokens" payload))
      (should-not (assoc "reasoning_effort" payload))
      (should (= (kargu-aget tuning "temperature") 0.5))
      (should (= (kargu-aget tuning "max_tokens") 8192))
      (should (equal (kargu-aget tuning "effort") "medium")))))

(ert-deftest kargu-providers-extract-models-test ()
  "`kargu--extract-models-from-json' handles data, models, and bare vectors."
  ;; OpenAI / standard style: {"data": [{"id": "m1"}]}
  (let ((res1 (kargu--extract-models-from-json '(("data" . [(("id" . "m1"))])))))
    (should (equal (kargu-aget (aref res1 0) "id") "m1")))
  ;; Gemini / Ollama style: {"models": [{"id": "m2"}]}
  (let ((res2 (kargu--extract-models-from-json '(("models" . [(("id" . "m2"))])))))
    (should (equal (kargu-aget (aref res2 0) "id") "m2")))
  ;; Bare vector style: [(("id" . "m3"))]
  (let ((res3 (kargu--extract-models-from-json [(("id" . "m3"))])))
    (should (equal (kargu-aget (car res3) "id") "m3"))))

(ert-deftest kargu-providers-tuning-cycle-test ()
  "`kargu-tune-cycle-reasoning-effort' cycles the model's API effort list."
  (require 'kargu/chat/tune)
  (require 'kargu/api/catalog)
  (let ((kargu-reasoning-effort nil)
        (kargu-session--context
         (kargu-test-session-with-history :model "test/cycle-model")))
    (kargu-model-set-metadata "test/cycle-model"
                              '(:id "cycle-model"
                                    :reasoning-efforts ("low" "medium" "high")))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq (kargu-selection-effort) 'low))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq (kargu-selection-effort) 'medium))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq (kargu-selection-effort) 'high))
    (kargu-tune-cycle-reasoning-effort)
    (should (null (kargu-selection-effort)))))

(ert-deftest kargu-providers-catalog-prompt-caching-completeness-test ()
  "Ensure every provider in `kargu-providers-builtin-catalog' defines `:prompt-caching'."
  (require 'kargu/providers/catalog)
  (should (> (length kargu-providers-builtin-catalog) 150))
  (dolist (item kargu-providers-builtin-catalog)
    (should (plist-member item :prompt-caching))
    (let ((val (plist-get item :prompt-caching)))
      (should (memq val '(t nil))))))

(ert-deftest kargu-providers-prompt-caching-resolution-test ()
  "Verify `kargu-provider-prompt-caching' correctly identifies caching providers."
  (require 'kargu/providers/catalog)
  (require 'kargu/providers/registry)
  ;; Supported providers
  (should (eq t (kargu-provider-prompt-caching "openrouter")))
  (should (eq t (kargu-provider-prompt-caching "anthropic")))
  (should (eq t (kargu-provider-prompt-caching "openai")))
  (should (eq t (kargu-provider-prompt-caching "deepseek")))
  (should (eq t (kargu-provider-prompt-caching "google")))
  (should (eq t (kargu-provider-prompt-caching "mistral")))
  (should (eq t (kargu-provider-prompt-caching "cerebras")))
  (should (eq t (kargu-provider-prompt-caching "togetherai")))
  ;; Unsupported providers
  (should (null (kargu-provider-prompt-caching "ollama")))
  (should (null (kargu-provider-prompt-caching "cohere")))
  (should (null (kargu-provider-prompt-caching "perplexity"))))

(ert-deftest kargu-providers-prompt-caching-is-captured-not-applied-by-editor-test ()
  "Editor captures native cache policy but leaves canonical history unchanged.
Marker placement cases moved to kargu-core/tests/api_wire.rs."
  (dolist (provider '("openrouter" "anthropic" "ollama"))
    (let* ((kargu-session--context
            (kargu-test-session-with-history
             :messages '((("role" . "system") ("content" . "Stable"))
                         (("role" . "user") ("content" . "one"))
                         (("role" . "assistant") ("content" . "answer"))
                         (("role" . "user") ("content" . "two")))
             :provider provider :model "fixture"))
           (settings (kargu-api-connection-settings provider "fixture"))
           (payload (kargu--build-payload)))
      (should (eq (plist-get settings :cache-marker)
                  (if (equal provider "ollama") nil t)))
      (should (equal (kargu-aget (aref (kargu-aget payload "messages") 0) "content") "Stable"))
      (should (equal (kargu-aget (aref (kargu-aget payload "messages") 2) "content") "answer"))
      (should-not (string-search "cache_control" (kargu-json-encode-record payload))))))

(ert-deftest kargu-providers-native-projection-preserves-explicit-override-test ()
  "A refreshed core baseline must not overwrite an editor registration."
  (let ((kargu-providers--table (copy-hash-table kargu-providers--table))
        (kargu-providers--baseline (copy-hash-table kargu-providers--baseline))
        (kargu-provider-formats (copy-tree kargu-provider-formats)))
    (kargu-register-provider :id "openai" :name "Explicit override" :api "http://localhost:1234/v1")
    (kargu-providers-install-projection kargu-providers--projection)
    (should (equal (kargu-provider-name "openai") "Explicit override"))
    (should (equal (kargu-provider-api "openai") "http://localhost:1234/v1"))
    (should (equal (cdr (assoc "HTTP-Referer" (kargu-provider-format-headers 'openrouter))) :app-url))
    (should (equal (cdr (assoc "x-session-id" (kargu-provider-extra-headers "openrouter"))) :session))))

(provide 'tests/test-providers)

;;; test-providers.el ends here
