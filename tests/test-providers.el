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
                    "apikey = \"sk-test-deepseek-12345\"\n"
                    "model = \"deepseek-chat\"\n"))
          (cl-letf (((symbol-function 'kargu-config-file) (lambda () temp-config)))
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
   :models-api "https://api.test-dynamic.ai/v1/models"
   :env '("TEST_DYNAMIC_API_KEY"))
  (should (equal (kargu-provider-api "test-dynamic-ai") "https://api.test-dynamic.ai/v1"))
  (should (equal (kargu-provider-models-api "test-dynamic-ai") "https://api.test-dynamic.ai/v1/models"))
  (should (equal (kargu-provider-name "test-dynamic-ai") "Test Dynamic AI"))
  (should (member "test-dynamic-ai" (kargu-provider-list))))

(ert-deftest kargu-providers-session-switch-test ()
  "`kargu-set-provider' sets session provider, model from live cache, and resolves correct API base."
  (let ((kargu--session-provider nil)
        (kargu--session-model nil))
    (puthash "cerebras" '("llama3.1-70b") kargu--live-models-cache)
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

(ert-deftest kargu-providers-prompt-caching-payload-tools-test ()
  "Ensure `kargu--build-payload' attaches `cache_control' to last tool for caching providers."
  (require 'kargu/api/http)
  (require 'kargu/api/tools)
  (let ((kargu--session-provider "openrouter")
        (kargu--session-model "anthropic/claude-3.5-sonnet")
        (kargu--message-history '((("role" . "user") ("content" . "hello")))))
    (let* ((payload (kargu--build-payload))
           (tools (kargu--aget payload "tools")))
      (should (vectorp tools))
      (should (> (length tools) 0))
      (let ((last-tool (aref tools (1- (length tools)))))
        (should (equal (kargu--aget last-tool "cache_control")
                       '(("type" . "ephemeral"))))))))

(ert-deftest kargu-providers-prompt-caching-payload-disabled-test ()
  "Ensure `kargu--build-payload' does not attach `cache_control' when provider does not support it."
  (require 'kargu/api/http)
  (require 'kargu/api/tools)
  (let ((kargu--session-provider "ollama")
        (kargu--session-model "llama3")
        (kargu--message-history '((("role" . "user") ("content" . "hello")))))
    (let* ((payload (kargu--build-payload))
           (tools (kargu--aget payload "tools")))
      (should (vectorp tools))
      (should (> (length tools) 0))
      (let ((last-tool (aref tools (1- (length tools)))))
        (should-not (assoc "cache_control" last-tool))))))

(ert-deftest kargu-providers-prompt-caching-payload-messages-multi-turn-test ()
  "Ensure `kargu--build-payload' attaches `cache_control' to last completed turn for caching providers."
  (require 'kargu/api/http)
  (require 'kargu/api/tools)
  (let ((kargu--session-provider "openrouter")
        (kargu--session-model "anthropic/claude-3.5-sonnet")
        (kargu--message-history '((("role" . "system") ("content" . "You are a coding assistant."))
                                  (("role" . "user") ("content" . "Hello 1"))
                                  (("role" . "assistant") ("content" . "Hi there 1"))
                                  (("role" . "user") ("content" . "Hello 2")))))
    (let* ((payload (kargu--build-payload))
           (msgs (kargu--aget payload "messages")))
      (should (vectorp msgs))
      (should (= (length msgs) 4))
      ;; Turn 2 (assistant) should have cache_control breakpoint
      (let ((prev-turn (aref msgs 2)))
        (should (equal (kargu--aget prev-turn "role") "assistant"))
        (should (equal (kargu--aget prev-turn "cache_control")
                       '(("type" . "ephemeral")))))
      ;; Latest turn (user 2) should NOT have cache_control
      (let ((curr-turn (aref msgs 3)))
        (should (equal (kargu--aget curr-turn "role") "user"))
        (should-not (assoc "cache_control" curr-turn))))))

(ert-deftest kargu-providers-prompt-caching-payload-empty-tools-system-test ()
  "Ensure `kargu--build-payload' attaches `cache_control' to system message when tools are empty."
  (require 'kargu/api/http)
  (require 'kargu/api/tools)
  (cl-letf (((symbol-function 'kargu--build-tools-vector) (lambda () [])))
    (let ((kargu--session-provider "anthropic")
          (kargu--session-model "claude-3-5-sonnet-20241022")
          (kargu--message-history '((("role" . "system") ("content" . "System instructions"))
                                    (("role" . "user") ("content" . "Hello")))))
      (let* ((payload (kargu--build-payload))
             (msgs (kargu--aget payload "messages")))
        (should (vectorp msgs))
        (let ((sys-msg (aref msgs 0)))
          (should (equal (kargu--aget sys-msg "role") "system"))
          (should (equal (kargu--aget sys-msg "cache_control")
                         '(("type" . "ephemeral")))))))))

(provide 'tests/test-providers)

;;; test-providers.el ends here
