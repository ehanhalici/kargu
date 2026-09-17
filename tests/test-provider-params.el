;;; tests/test-provider-params.el --- Unit tests for provider JSON parameters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for provider JSON parameter schemas, format profiles (OpenAPI,
;; OpenRouter, Anthropic, Gemini, Ollama), storage, payload assembly, and UI formatting.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/providers)
(require 'kargu/providers/params)
(require 'kargu/chat/tune-params)
(require 'kargu/api/http)

(ert-deftest kargu-provider-format-detection-test ()
  "Test format profile resolution for standard and non-standard providers."
  (should (eq (kargu-provider-format "openrouter") 'openrouter))
  (should (eq (kargu-provider-format-type "openrouter") 'openrouter))
  ;; OpenAPI standard providers
  (should (eq (kargu-provider-format "vivgrid") 'openapi))
  (should (eq (kargu-provider-format-type "vivgrid") 'openapi))
  (should (eq (kargu-provider-format-type "openai") 'openapi))
  (should (eq (kargu-provider-format-type "groq") 'openapi))
  (should (eq (kargu-provider-format-type "deepseek") 'openapi))
  (should (eq (kargu-provider-format-type "togetherai") 'openapi))
  ;; Anthropic format providers
  (should (eq (kargu-provider-format-type "anthropic") 'anthropic))
  (should (eq (kargu-provider-format-type "google-vertex-anthropic") 'anthropic))
  (should (eq (kargu-provider-format-type "minimax-cn-coding-plan") 'anthropic))
  ;; Gemini format providers
  (should (eq (kargu-provider-format-type "google") 'gemini))
  (should (eq (kargu-provider-format-type "google-vertex") 'gemini))
  ;; Ollama format providers
  (should (eq (kargu-provider-format-type "ollama") 'ollama))
  (should (eq (kargu-provider-format-type "llamacpp") 'ollama))
  ;; Unsupported format providers (returns nil)
  (should (null (kargu-provider-format-type "amazon-bedrock")))
  (should (null (kargu-provider-format-type "azure")))
  (should (null (kargu-provider-format-type "cohere")))
  (should (null (kargu-provider-format-type "gitlab")))
  (should (null (kargu-provider-format-type "sap-ai-core"))))

(ert-deftest kargu-provider-params-schema-registration-test ()
  "Test that OpenRouter, OpenAPI, Anthropic, and Gemini schemas are registered."
  (let ((or-specs (kargu-provider-params-specs "openrouter"))
        (ai-specs (kargu-provider-params-specs "openapi"))
        (ant-specs (kargu-provider-params-specs "anthropic"))
        (gem-specs (kargu-provider-params-specs "gemini"))
        (viv-specs (kargu-provider-params-specs "vivgrid")))
    ;; OpenRouter specs
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "sort")) or-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "zdr")) or-specs))
    ;; OpenAPI specs (and inherited by vivgrid)
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "service_tier")) ai-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "seed")) viv-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "top_p")) viv-specs))
    ;; Anthropic specs
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "extended_thinking")) ant-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "thinking_budget")) ant-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "top_k")) ant-specs))
    ;; Gemini specs
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "thinking_budget")) gem-specs))
    (should (cl-find-if (lambda (s) (equal (plist-get s :key) "response_mime_type")) gem-specs))))

(ert-deftest kargu-provider-params-enum-cycling-test ()
  "Test cycling enum parameters for OpenRouter and OpenAPI."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "openrouter")
    ;; nil -> price -> throughput -> latency -> nil
    (should (equal (kargu-provider-param-toggle "sort" "openrouter") "price"))
    (should (equal (kargu-provider-param-get "sort" "openrouter") "price"))
    (should (equal (kargu-provider-param-toggle "sort" "openrouter") "throughput"))
    (should (equal (kargu-provider-param-toggle "sort" "openrouter") "latency"))
    (should-not (kargu-provider-param-toggle "sort" "openrouter"))
    ;; OpenAPI service tier cycling
    (kargu-provider-params-reset "vivgrid")
    (should (equal (kargu-provider-param-toggle "service_tier" "vivgrid") "auto"))
    (should (equal (kargu-provider-param-toggle "service_tier" "vivgrid") "default"))))

(ert-deftest kargu-provider-params-boolean-toggle-test ()
  "Test tri-state boolean toggling (nil -> t -> :json-false -> nil)."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "openrouter")
    (should-not (kargu-provider-param-get "zdr" "openrouter"))
    (should (eq (kargu-provider-param-toggle "zdr" "openrouter") t))
    (should (eq (kargu-provider-param-get "zdr" "openrouter") t))
    (should (eq (kargu-provider-param-toggle "zdr" "openrouter") :json-false))
    (should (eq (kargu-provider-param-get "zdr" "openrouter") :json-false))
    (should-not (kargu-provider-param-toggle "zdr" "openrouter"))
    ;; Parallel tool calls toggle on vivgrid
    (kargu-provider-params-reset "vivgrid")
    (should (eq (kargu-provider-param-toggle "parallel_tool_calls" "vivgrid") t))
    (should (eq (kargu-provider-param-toggle "parallel_tool_calls" "vivgrid") :json-false))
    (should-not (kargu-provider-param-toggle "parallel_tool_calls" "vivgrid"))))

(ert-deftest kargu-provider-params-string-list-parsing-test ()
  "Test comma-separated string parsing into vectors."
  (let ((vec (kargu--parse-string-list-input "Anthropic, Together , DeepInfra")))
    (should (vectorp vec))
    (should (= (length vec) 3))
    (should (equal (aref vec 0) "Anthropic"))
    (should (equal (aref vec 1) "Together"))
    (should (equal (aref vec 2) "DeepInfra")))
  (let ((empty (kargu--parse-string-list-input "")))
    (should-not empty)))

(ert-deftest kargu-provider-params-openrouter-payload-assembly-test ()
  "Test assembling OpenRouter request payload under \"provider\": { ... }."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "openrouter")
    (should-not (kargu-provider-params-build-payload "openrouter"))
    (kargu-provider-param-set "sort" "price" "openrouter")
    (kargu-provider-param-set "allow_fallbacks" :json-false "openrouter")
    (kargu-provider-param-set "zdr" t "openrouter")
    (kargu-provider-param-set "quantizations" '("fp16" "bf16") "openrouter")
    (kargu-provider-param-set "order" "Anthropic, Together" "openrouter")
    (kargu-provider-param-set "preferred_min_throughput" 35 "openrouter")
    (let* ((payload (kargu-provider-params-build-payload "openrouter"))
           (provider-block (cdr (assoc "provider" payload))))
      (should (consp payload))
      (should (consp provider-block))
      (should (equal (cdr (assoc "sort" provider-block)) "price"))
      (should (eq (cdr (assoc "allow_fallbacks" provider-block)) :json-false))
      (should (eq (cdr (assoc "zdr" provider-block)) t))
      (should (equal (cdr (assoc "quantizations" provider-block)) ["fp16" "bf16"]))
      (should (equal (cdr (assoc "order" provider-block)) ["Anthropic" "Together"]))
      (should (= (cdr (assoc "preferred_min_throughput" provider-block)) 35))
      (let ((json-str (kargu--json-encode payload)))
        (should (string-match-p "\"provider\":{" json-str))
        (should (string-match-p "\"sort\":\"price\"" json-str))
        (should (string-match-p "\"allow_fallbacks\":false" json-str))
        (should (string-match-p "\"zdr\":true" json-str))))))

(ert-deftest kargu-provider-params-openapi-vivgrid-payload-assembly-test ()
  "Test assembling Universal OpenAPI parameters for Vivgrid."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "vivgrid")
    (kargu-provider-param-set "seed" 777 "vivgrid")
    (kargu-provider-param-set "top_p" 0.85 "vivgrid")
    (kargu-provider-param-set "service_tier" "flex" "vivgrid")
    (kargu-provider-param-set "parallel_tool_calls" t "vivgrid")
    (let ((payload (kargu-provider-params-build-payload "vivgrid")))
      (should (consp payload))
      (should (= (cdr (assoc "seed" payload)) 777))
      (should (= (cdr (assoc "top_p" payload)) 0.85))
      (should (equal (cdr (assoc "service_tier" payload)) "flex"))
      (should (eq (cdr (assoc "parallel_tool_calls" payload)) t))
      ;; No provider wrapper for OpenAPI standard
      (should-not (assoc "provider" payload)))))

(ert-deftest kargu-provider-params-anthropic-payload-assembly-test ()
  "Test assembling Anthropic Messages API payload."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "anthropic")
    (kargu-provider-param-set "thinking_budget" 4096 "anthropic")
    (kargu-provider-param-set "top_k" 30 "anthropic")
    (kargu-provider-param-set "user_id" "dev-user" "anthropic")
    (let* ((payload (kargu-provider-params-build-payload "anthropic"))
           (thinking-block (cdr (assoc "thinking" payload)))
           (metadata-block (cdr (assoc "metadata" payload))))
      (should (consp payload))
      ;; Thinking sub-object
      (should (equal (cdr (assoc "type" thinking-block)) "enabled"))
      (should (= (cdr (assoc "budget_tokens" thinking-block)) 4096))
      ;; Top K
      (should (= (cdr (assoc "top_k" payload)) 30))
      ;; Metadata user_id
      (should (equal (cdr (assoc "user_id" metadata-block)) "dev-user")))))

(ert-deftest kargu-provider-params-gemini-payload-assembly-test ()
  "Test assembling Google Gemini GenerateContent API payload."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "google")
    (kargu-provider-param-set "thinking_budget" 2048 "google")
    (kargu-provider-param-set "top_p" 0.95 "google")
    (kargu-provider-param-set "response_mime_type" "application/json" "google")
    (kargu-provider-param-set "safety_threshold" "BLOCK_NONE" "google")
    (let* ((payload (kargu-provider-params-build-payload "google"))
           (gen-cfg (cdr (assoc "generationConfig" payload)))
           (safety (cdr (assoc "safetySettings" payload))))
      (should (consp payload))
      (should (= (cdr (assoc "topP" gen-cfg)) 0.95))
      (should (equal (cdr (assoc "responseMimeType" gen-cfg)) "application/json"))
      (let ((thinking-cfg (cdr (assoc "thinkingConfig" gen-cfg))))
        (should (= (cdr (assoc "thinkingBudget" thinking-cfg)) 2048)))
      (should (vectorp safety))
      (should (> (length safety) 0)))))

(ert-deftest kargu-provider-params-ollama-payload-assembly-test ()
  "Test assembling Ollama options payload."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "ollama")
    (kargu-provider-param-set "num_ctx" 16384 "ollama")
    (kargu-provider-param-set "repeat_penalty" 1.15 "ollama")
    (let* ((payload (kargu-provider-params-build-payload "ollama"))
           (opts (cdr (assoc "options" payload))))
      (should (consp opts))
      (should (= (cdr (assoc "num_ctx" opts)) 16384))
      (should (= (cdr (assoc "repeat_penalty" opts)) 1.15)))))

(ert-deftest kargu-provider-params-http-build-payload-integration-test ()
  "Test integration of provider params inside `kargu--build-payload'."
  (let ((kargu--session-provider-params nil)
        (kargu--session-provider "openrouter")
        (kargu--session-model "anthropic/claude-3.5-sonnet")
        (kargu--message-history '((("role" . "user") ("content" . "hi")))))
    (kargu-provider-params-reset "openrouter")
    (kargu-provider-param-set "sort" "throughput" "openrouter")
    (kargu-provider-param-set "zdr" t "openrouter")
    (let* ((payload (kargu--build-payload))
           (p-block (cdr (assoc "provider" payload))))
      (should (consp p-block))
      (should (equal (cdr (assoc "sort" p-block)) "throughput"))
      (should (eq (cdr (assoc "zdr" p-block)) t)))))

(ert-deftest kargu-provider-params-ui-formatting-test ()
  "Test UI description helpers and formatting in English."
  (let ((kargu--session-provider "openrouter")
        (kargu--session-provider-params nil))
    (kargu-provider-params-reset "openrouter")
    ;; Boolean format
    (should (string-match-p "default" (kargu-tune--format-bool nil)))
    (should (string-match-p "ON" (kargu-tune--format-bool t)))
    (should (string-match-p "OFF" (kargu-tune--format-bool :json-false)))
    ;; Descriptions when default
    (should (string-match-p "default" (kargu-tune--param-sort-desc)))
    (should (string-match-p "default" (kargu-tune--param-zdr-desc)))
    (should (string-match-p "defaults" (kargu-tune--provider-params-summary-desc)))
    ;; Descriptions when active
    (kargu-provider-param-set "sort" "price" "openrouter")
    (kargu-provider-param-set "zdr" t "openrouter")
    (should (string-match-p "PRICE" (kargu-tune--param-sort-desc)))
    (should (string-match-p "ON" (kargu-tune--param-zdr-desc)))
    (should (string-match-p "2 active" (kargu-tune--provider-params-summary-desc)))))

(ert-deftest kargu-provider-params-custom-body-merge-test ()
  "Test custom JSON body merging directly into top-level payload."
  (let ((kargu--session-provider-params nil))
    (kargu-provider-params-reset "openai")
    (kargu-provider-param-set "seed" 42 "openai")
    (kargu-provider-param-set "custom_body" '(("extra_feature" . "enabled")) "openai")
    (let ((payload (kargu-provider-params-build-payload "openai")))
      (should (= (cdr (assoc "seed" payload)) 42))
      (should (equal (cdr (assoc "extra_feature" payload)) "enabled")))))

(ert-deftest kargu-openrouter-menu-keys-and-no-reasoning-effort-test ()
  "Verify OpenRouter parameters schema has no reasoning_effort and menu has no key collision on 'q'."
  ;; 1. OpenRouter schema must not contain reasoning_effort
  (let* ((specs (kargu-provider-params-specs "openrouter"))
         (keys (mapcar (lambda (s) (plist-get s :key)) specs)))
    (should-not (member "reasoning_effort" keys)))
  ;; 2. Transient menu bindings
  (when (fboundp 'transient-get-suffix)
    (let ((quit-suffix (ignore-errors (transient-get-suffix 'kargu-tune-openrouter-menu "q")))
          (quant-suffix (ignore-errors (transient-get-suffix 'kargu-tune-openrouter-menu "Q")))
          (effort-suffix (ignore-errors (transient-get-suffix 'kargu-tune-openrouter-menu "e"))))
      ;; 'q' is bound to quit
      (should quit-suffix)
      (should (eq (plist-get (cdr quit-suffix) :command) 'transient-quit-one))
      ;; 'Q' is bound to quantizations
      (should quant-suffix)
      (should (eq (plist-get (cdr quant-suffix) :command) 'kargu-tune-param-select-quantizations))
      ;; 'e' is not present
      (should-not effort-suffix))))

(provide 'tests/test-provider-params)

;;; test-provider-params.el ends here
