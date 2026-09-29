;;; tests/test-dynamic-models.el --- Tests for dynamic provider models & live metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Ensure the package root is on `load-path` during byte/native compilation.
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/providers/registry)
(require 'kargu/api)
(require 'kargu/api/http)

(declare-function kargu-model-read "kargu/api/catalog" (&optional model-id))

(ert-deftest kargu-dynamic-models-openrouter-metadata-test ()
  "Test parsing and metadata extraction from OpenRouter /models schema."
  (let ((kargu--model-metadata-table (make-hash-table :test 'equal))
        (models-json
         '((("id" . "deepseek/deepseek-r1")
            ("context_length" . 131072)
            ("pricing" . ((("prompt" . "0.00000055")
                           ("completion" . "0.00000219"))))
            ("top_provider" . ((("max_completion_tokens" . 8192))))
            ("reasoning" . ((("supported_efforts" . ["low" "medium" "high"]))))
            ("architecture" . ((("modality" . "text->text")))))
           (("id" . "qwen/qwen-2.5-vl-72b-instruct:free")
            ("context_length" . 32768)
            ("pricing" . ((("prompt" . "0")
                           ("completion" . "0"))))
            ("top_provider" . ((("max_completion_tokens" . 4096))))
            ("architecture" . ((("modality" . "text+image->text"))))))))
    (kargu--record-models-metadata models-json "openrouter")
    ;; The store keeps the raw alist.  One reader extracts the fields.
    (let ((fields (kargu-model-read "deepseek/deepseek-r1")))
      (should (consp (kargu-model-get-metadata "deepseek/deepseek-r1")))
      (should (= (plist-get fields :context-window) 131072))
      (should (= (plist-get fields :max-output) 8192))
      (should (equal (plist-get fields :reasoning-efforts) '("low" "medium" "high")))
      (let ((ann (kargu-model-annotation-string "deepseek/deepseek-r1" "openrouter")))
        (should (string-match-p "131k ctx" ann))
        (should (string-match-p "max 8k" ann))
        (should (string-match-p "🧠 think: low..high" ann))
        (should (string-match-p "\\$0.55/1M" ann))))
    (let ((fields (kargu-model-read "qwen/qwen-2.5-vl-72b-instruct:free")))
      (should (= (plist-get fields :context-window) 32768))
      (should (plist-get fields :vision))
      (should (plist-get fields :free))
      (let ((ann (kargu-model-annotation-string "qwen/qwen-2.5-vl-72b-instruct:free" "openrouter")))
        (should (string-match-p "32k ctx" ann))
        (should (string-match-p "👁 vision" ann))
        (should (string-match-p "⚡ free" ann))))))

(ert-deftest kargu-dynamic-models-ollama-schema-test ()
  "Test parsing Ollama /api/tags schema with details and parameter sizes."
  (let ((kargu--model-metadata-table (make-hash-table :test 'equal))
        (ollama-json
         '((("name" . "llama3.3:70b")
            ("details" . ((("parameter_size" . "70.6B")
                           ("quantization_level" . "Q4_K_M")
                           ("family" . "llama")))))
           (("name" . "deepseek-r1:32b")
            ("details" . ((("parameter_size" . "32.8B")
                           ("quantization_level" . "Q4_K_M"))))))))
    (kargu--record-models-metadata ollama-json "ollama")
    (let ((llama (kargu-model-read "llama3.3:70b"))
          (r1 (kargu-model-read "deepseek-r1:32b")))
      (should (equal (plist-get llama :params) "70.6B Q4_K_M"))
      (should (equal (plist-get r1 :params) "32.8B Q4_K_M"))
      ;; The name "r1" is not a reasoning flag.  The record omitted one.
      (should-not (plist-get r1 :reasoning-efforts))
      (let ((ann1 (kargu-model-annotation-string "llama3.3:70b" "ollama"))
            (ann2 (kargu-model-annotation-string "deepseek-r1:32b" "ollama")))
        (should (string-match-p "70.6B Q4_K_M" ann1))
        (should (string-match-p "32.8B Q4_K_M" ann2))
        (should-not (string-match-p "🧠 think" ann2))))))

(ert-deftest kargu-dynamic-models-google-gemini-schema-test ()
  "Test parsing Google Gemini inputTokenLimit & outputTokenLimit schema."
  (let ((kargu--model-metadata-table (make-hash-table :test 'equal))
        (gemini-json
         '((("name" . "models/gemini-1.5-pro")
            ("inputTokenLimit" . 2097152)
            ("outputTokenLimit" . 8192)
            ("description" . "Mid-size multimodal model"))
           (("name" . "models/gemini-2.0-flash")
            ("inputTokenLimit" . 1048576)
            ("outputTokenLimit" . 8192)
            ("description" . "Fast next-gen model")))))
    (kargu--record-models-metadata gemini-json "google")
    (let ((pro (kargu-model-read "gemini-1.5-pro"))
          (flash (kargu-model-read "gemini-2.0-flash")))
      (should (= (plist-get pro :context-window) 2097152))
      (should (= (plist-get pro :max-output) 8192))
      (should (= (plist-get flash :context-window) 1048576))
      (let ((ann (kargu-model-annotation-string "gemini-1.5-pro" "google")))
        (should (string-match-p "2m ctx" ann))
        (should (string-match-p "max 8k" ann))))))

(ert-deftest kargu-dynamic-models-custom-provider-endpoints-test ()
  "Test provider registration with dedicated models-api, usage-api, and extra-headers."
  (kargu-register-provider
   :id "test-provider-custom"
   :name "Test Custom Provider"
   :api "https://api.custom.ai/v1"
   :models-api "https://api.custom.ai/v2/catalog/models"
   :usage-api "https://api.custom.ai/v1/user/usage"
   :extra-headers '(("X-Custom-Header" . "CustomVal"))
   :env '("CUSTOM_AI_KEY"))
  (should (equal (kargu-provider-models-api "test-provider-custom") "https://api.custom.ai/v2/catalog/models"))
  (should (equal (kargu-provider-usage-api "test-provider-custom") "https://api.custom.ai/v1/user/usage"))
  (should (equal (kargu-provider-extra-headers "test-provider-custom") '(("X-Custom-Header" . "CustomVal"))))
  ;; Check header generation
  (let ((headers (kargu--api-headers "test-secret" "test-provider-custom")))
    (should (assoc "X-Custom-Header" headers))
    (should (equal (cdr (assoc "X-Custom-Header" headers)) "CustomVal"))))

(ert-deftest kargu-provider-catalog-endpoints-test ()
  "Test that provider endpoints are dynamic and no hallucinated models are statically registered."
  (let ((opencode-models (kargu-provider-models "opencode")))
    ;; Static models should not exist
    (should-not opencode-models)
    (should (equal (kargu-provider-models-api "opencode") "https://opencode.ai/zen/v1/models"))
    (should (equal (kargu-provider-usage-api "opencode") "https://opencode.ai/zen/v1/user"))))

(provide 'tests/test-dynamic-models)
;;; test-dynamic-models.el ends here
