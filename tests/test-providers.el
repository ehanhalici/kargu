;;; tests/test-providers.el --- Tests for Provider Registry & Zero-URL Config -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests for `kargu/providers', built-in catalog lookups,
;; automatic endpoint resolution without specifying `api' in TOML,
;; user URL overrides, and provider-specific environment key resolution.

;;; Code:

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
  "Built-in providers must supply known model defaults."
  (should (member "deepseek-chat" (kargu-provider-models "deepseek")))
  (should (member "llama-3.3-70b-versatile" (kargu-provider-models "groq")))
  (should (member "gpt-4o" (kargu-provider-models "openai")))
  (should (member "claude-3-5-sonnet-latest" (kargu-provider-models "anthropic")))
  (should (member "qwen2.5-coder:latest" (kargu-provider-models "ollama"))))

(ert-deftest kargu-providers-zero-url-toml-config-test ()
  "When TOML specifies only `apikey', URL is automatically resolved."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu--config-cache nil)
         (kargu--config-cache-path nil)
         (kargu--config-mtime nil)
         (kargu--session-provider nil)
         (kargu--session-model nil))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"deepseek\"\n\n"
                    "[providers.deepseek]\n"
                    "apikey = \"sk-test-deepseek-12345\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
            (should (equal (kargu--provider-name) "deepseek"))
            ;; API base should resolve to DeepSeek's default URL automatically:
            (should (equal (kargu--api-base) "https://api.deepseek.com/v1"))
            ;; Model should resolve from DeepSeek's known models:
            (should (equal (kargu--model) "deepseek-chat"))
            ;; API key should resolve to the configured key:
            (should (equal (kargu--resolve-api-key) "sk-test-deepseek-12345"))))
      (delete-file temp-config))))

(ert-deftest kargu-providers-custom-url-override-test ()
  "When user specifies custom `api' in TOML, it overrides the built-in default."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu--config-cache nil)
         (kargu--config-cache-path nil)
         (kargu--config-mtime nil)
         (kargu--session-provider nil)
         (kargu--session-model nil))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"deepseek\"\n\n"
                    "[providers.deepseek]\n"
                    "api = \"https://my-custom-proxy.internal/v1\"\n"
                    "apikey = \"sk-test-custom-key\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
            (should (equal (kargu--provider-name) "deepseek"))
            ;; User-provided API base must take precedence:
            (should (equal (kargu--api-base) "https://my-custom-proxy.internal/v1"))
            (should (equal (kargu--resolve-api-key) "sk-test-custom-key"))))
      (delete-file temp-config))))

(ert-deftest kargu-providers-env-key-resolution-test ()
  "Environment variable specific to active provider is used if TOML omits apikey."
  (let* ((temp-config (make-temp-file "kargu-test-config-" nil ".toml"))
         (kargu--config-cache nil)
         (kargu--config-cache-path nil)
         (kargu--config-mtime nil)
         (kargu--session-provider "groq")
         (kargu-api-key nil))
    (unwind-protect
        (progn
          (with-temp-file temp-config
            (insert "provider = \"groq\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
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
   :env '("TEST_DYNAMIC_API_KEY")
   :models '("dynamic-model-1" "dynamic-model-2"))
  (should (equal (kargu-provider-api "test-dynamic-ai") "https://api.test-dynamic.ai/v1"))
  (should (equal (kargu-provider-name "test-dynamic-ai") "Test Dynamic AI"))
  (should (equal (kargu-provider-models "test-dynamic-ai") '("dynamic-model-1" "dynamic-model-2")))
  (should (member "test-dynamic-ai" (kargu-provider-list))))

(ert-deftest kargu-providers-session-switch-test ()
  "`kargu-set-provider' sets session provider, model, and resolves correct API base."
  (let ((kargu--session-provider nil)
        (kargu--session-model nil))
    (kargu-set-provider "cerebras")
    (should (equal kargu--session-provider "cerebras"))
    (should (equal (kargu--api-base) "https://api.cerebras.ai/v1"))
    (should (equal kargu--session-model "llama3.1-70b"))))

(ert-deftest kargu-providers-authentication-detection-test ()
  "Keyless local runners and env-configured providers report authenticated."
  ;; Ollama is a keyless local runner
  (should (kargu-provider-authenticated-p "ollama"))
  (should (member "ollama" (kargu-connected-providers)))
  ;; Without key, a random cloud provider is not authenticated
  (let* ((empty-cfg (make-temp-file "kargu-empty-" nil ".toml"))
         (kargu--config-cache nil)
         (kargu--config-cache-path nil)
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
  "Payload builder respects reasoning effort, thinking budget, and max tokens."
  (let ((kargu-reasoning-effort 'medium)
        (kargu-thinking-budget 4096)
        (kargu-max-tokens 8192)
        (kargu-temperature 0.5)
        (kargu--session-provider "deepseek")
        (kargu--session-model "deepseek-chat")
        (kargu--message-history '((("role" . "user") ("content" . "hello")))))
    (let ((payload (kargu--build-payload)))
      (should (equal (kargu--aget payload "model") "deepseek-chat"))
      (should (equal (kargu--aget payload "temperature") 0.5))
      (should (equal (kargu--aget payload "max_tokens") 8192))
      (should (equal (kargu--aget payload "max_completion_tokens") 8192))
      (should (equal (kargu--aget payload "reasoning_effort") "medium"))
      (let ((reasoning (kargu--aget payload "reasoning")))
        (should (equal (kargu--aget reasoning "effort") "medium"))
        (should (equal (kargu--aget reasoning "max_tokens") 4096)))
      (let ((thinking (kargu--aget payload "thinking")))
        (should (equal (kargu--aget thinking "type") "enabled"))
        (should (equal (kargu--aget thinking "budget_tokens") 4096))))))

(ert-deftest kargu-providers-extract-models-test ()
  "`kargu--extract-models-from-json' handles data, models, and bare vectors."
  ;; OpenAI / standard style: {"data": [{"id": "m1"}]}
  (let ((res1 (kargu--extract-models-from-json '(("data" . [(("id" . "m1"))])))))
    (should (equal (kargu--aget (aref res1 0) "id") "m1")))
  ;; Gemini / Ollama style: {"models": [{"id": "m2"}]}
  (let ((res2 (kargu--extract-models-from-json '(("models" . [(("id" . "m2"))])))))
    (should (equal (kargu--aget (aref res2 0) "id") "m2")))
  ;; Bare vector style: [(("id" . "m3"))]
  (let ((res3 (kargu--extract-models-from-json [(("id" . "m3"))])))
    (should (equal (kargu--aget (car res3) "id") "m3"))))

(ert-deftest kargu-providers-tuning-cycle-test ()
  "`kargu-tune-cycle-reasoning-effort' cycles nil -> low -> medium -> high -> nil."
  (require 'kargu/chat/tune)
  (let ((kargu-reasoning-effort nil))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq kargu-reasoning-effort 'low))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq kargu-reasoning-effort 'medium))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq kargu-reasoning-effort 'high))
    (kargu-tune-cycle-reasoning-effort)
    (should (null kargu-reasoning-effort))))

(provide 'tests/test-providers)

;;; test-providers.el ends here
