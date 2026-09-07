;;; tests/test-dynamic-models.el --- Tests for dynamic provider models & live metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/providers/registry)
(require 'kargu/api)
(require 'kargu/api/http)

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
    ;; 1. Check DeepSeek R1 metadata
    (let ((meta (kargu-model-get-metadata "deepseek/deepseek-r1")))
      (should meta)
      (should (= (plist-get meta :context-window) 131072))
      (should (= (plist-get meta :max-output) 8192))
      (should (equal (plist-get meta :reasoning-efforts) '("low" "medium" "high")))
      ;; Annotation string check
      (let ((ann (kargu-model-annotation-string "deepseek/deepseek-r1" "openrouter")))
        (should (string-match-p "131k ctx" ann))
        (should (string-match-p "max 8k" ann))
        (should (string-match-p "🧠 think: low..high" ann))
        (should (string-match-p "\\$0.55/1M" ann))))
    ;; 2. Check Qwen VL Free metadata
    (let ((meta (kargu-model-get-metadata "qwen/qwen-2.5-vl-72b-instruct:free")))
      (should meta)
      (should (= (plist-get meta :context-window) 32768))
      (should (plist-get meta :vision))
      (should (plist-get meta :free))
      ;; Annotation string check
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
    (let ((meta1 (kargu-model-get-metadata "llama3.3:70b"))
          (meta2 (kargu-model-get-metadata "deepseek-r1:32b")))
      (should meta1)
      (should (equal (plist-get meta1 :params) "70.6B Q4_K_M"))
      (should meta2)
      (should (equal (plist-get meta2 :params) "32.8B Q4_K_M"))
      (should (plist-get meta2 :supports-reasoning))
      ;; Check annotation strings
      (let ((ann1 (kargu-model-annotation-string "llama3.3:70b" "ollama"))
            (ann2 (kargu-model-annotation-string "deepseek-r1:32b" "ollama")))
        (should (string-match-p "70.6B Q4_K_M" ann1))
        (should (string-match-p "32.8B Q4_K_M" ann2))
        (should (string-match-p "🧠 think" ann2))))))

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
    (let ((meta-pro (kargu-model-get-metadata "gemini-1.5-pro"))
          (meta-flash (kargu-model-get-metadata "gemini-2.0-flash")))
      (should meta-pro)
      (should (= (plist-get meta-pro :context-window) 2097152))
      (should (= (plist-get meta-pro :max-output) 8192))
      (should meta-flash)
      (should (= (plist-get meta-flash :context-window) 1048576))
      ;; Annotation string check
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

(provide 'tests/test-dynamic-models)
;;; test-dynamic-models.el ends here
