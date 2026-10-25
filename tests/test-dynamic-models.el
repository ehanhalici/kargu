;;; tests/test-dynamic-models.el --- Tests for dynamic provider models & live metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provider discovery, editor metadata projection and owned catalog callbacks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/providers/registry)
(require 'kargu/api)
(require 'kargu/api/http)

(declare-function kargu-model-read "kargu/api/catalog" (&optional model-id provider))

(ert-deftest kargu-catalog-public-opencode-does-not-resolve-secrets-test ()
  "Only the declared public endpoint skips authentication, not custom URLs."
  (dolist (provider '("opencode" "opencode-go"))
    (let ((kargu--live-models-cache (make-hash-table :test #'equal)) seen result)
      (cl-letf (((symbol-function 'kargu--resolve-direct-api-key)
                 (lambda (_) (error "Secret lookup must not run")))
                ((symbol-function 'kargu-transport-request)
                 (lambda (_method url &rest options)
                   (setq seen url)
                   (should (plist-get options :timeout))
                   (should (plist-get options :model-catalog))
                   (should (eq (kargu-aget (plist-get options :auth) "key") :json-null))
                   (funcall (plist-get options :then) "{\"models\":[{\"id\":\"live-model\"}]}"))))
        (kargu-api-fetch-model-ids provider (lambda (ids) (setq result ids)))
        (kargu-test-drain-model-publishers)
        (should (equal seen (kargu-provider-models-api provider)))
        (should (equal result '("live-model")))))
    (should-not (kargu-provider-public-models-p "opencode" "https://private.example/models"))))

(ert-deftest kargu-catalog-concurrent-requests-deliver-once-test ()
  "Every request delivers even out of order; only the latest writes cache."
  (let ((kargu--catalog-generations (make-hash-table :test #'equal))
        (kargu--live-models-cache (make-hash-table :test #'equal))
        pending results)
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options) (push options pending) nil)))
      (kargu-api-fetch-model-ids "opencode" (lambda (ids) (push (cons 'old ids) results)))
      (kargu-api-fetch-model-ids "opencode-go" (lambda (ids) (push (cons 'other ids) results)))
      (kargu-api-fetch-model-ids "opencode" (lambda (ids) (push (cons 'new ids) results)))
      (funcall (plist-get (nth 0 pending) :then) "{\"models\":[{\"id\":\"new\"}]}")
      (kargu-test-drain-model-publishers)
      (funcall (plist-get (nth 1 pending) :then) "{\"models\":[{\"id\":\"other\"}]}")
      (kargu-test-drain-model-publishers)
      (funcall (plist-get (nth 2 pending) :then) "{\"models\":[{\"id\":\"old\"}]}")
      (kargu-test-drain-model-publishers)
      (funcall (plist-get (nth 2 pending) :else) 'late-error)
      (should (= (length results) 3))
      (should (equal (gethash "opencode" kargu--live-models-cache) '("new")))
      (should (equal (cdr (assq 'old results)) '("old")))
      (should (equal (gethash "opencode-go" kargu--live-models-cache) '("other"))))))

(ert-deftest kargu-catalog-custom-url-still-requires-auth-test ()
  "A private override cannot inherit public access from the standard catalog."
  (let (requested result)
    (cl-letf (((symbol-function 'kargu--api-base) (lambda (_) "https://private.example/v1"))
              ((symbol-function 'kargu--resolve-direct-api-key) (lambda (_) nil))
              ((symbol-function 'kargu-config-worker-resolve)
               (lambda (_provider _host task &rest _options)
                 (kargu-async-finish task (kargu-err "No synthetic key" :auth-unavailable))))
              ((symbol-function 'kargu-transport-request) (lambda (&rest _) (setq requested t))))
      (kargu-api-list-models (lambda (value) (setq result value)) "opencode")
      (should-not requested)
      (should (string-search "API key" (kargu-aget (kargu-aget result "error") "message"))))))

(ert-deftest kargu-catalog-stale-selection-does-not-open-ui-test ()
  "Provider changes and a closed origin buffer cannot reopen old selectors."
  (let ((buffer (generate-new-buffer " *catalog selection*")) held opened
        (provider "opencode")
        (kargu--live-models-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-api-select--guard) #'ignore)
                  ((symbol-function 'kargu--provider-name) (lambda () provider))
                  ((symbol-function 'kargu-api-fetch-model-ids)
                   (lambda (_provider callback &optional _error) (setq held callback)))
                  ((symbol-function 'kargu-chat--open-model-selector)
                   (lambda (&rest _) (setq opened t))))
          (with-current-buffer buffer (kargu-chat-select-model-company))
          (setq provider "opencode-go")
          (funcall held '("old"))
          (should-not opened)
          (kill-buffer buffer)
          (setq provider "opencode")
          (funcall held '("old"))
          (should-not opened))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kargu-catalog-empty-timeout-and-prefetch-retry-test ()
  "Empty catalogs clear stale IDs; timed out prefetches can be retried."
  (let ((kargu--models-prefetched (make-hash-table :test #'equal))
        (kargu--live-models-cache (make-hash-table :test #'equal))
        pending task)
    (puthash "opencode" '("stale") kargu--live-models-cache)
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options) (setq pending options) nil)))
      (setq task (kargu-api-list-models #'ignore "opencode"))
      (funcall (plist-get pending :then) "{\"models\":[]}")
      (kargu-test-drain-model-publishers)
      (should-not (gethash "opencode" kargu--live-models-cache))
      (should-not (kargu-async-task-timer task))
      (kargu--prefetch-models-once "opencode")
      (setq task (car kargu-async--pending))
      (kargu-async-finish task nil "Request timed out")
      (should-not (gethash "opencode" kargu--models-prefetched))
      (kargu--prefetch-models-once "opencode")
      (funcall (plist-get pending :then) "{\"models\":[]}")
      (kargu-test-drain-model-publishers)
      (should (eq (gethash "opencode" kargu--models-prefetched) :ready)))))

(ert-deftest kargu-dynamic-models-openrouter-metadata-test ()
  "Test parsing and metadata extraction from OpenRouter /models schema."
  (let (
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
    (kargu-test-publish-model-catalog models-json "openrouter")
    ;; The store keeps the raw alist.  One reader extracts the fields.
    (let ((fields (kargu-model-read "deepseek/deepseek-r1" "openrouter")))
      (should (consp (kargu-model-get-metadata "deepseek/deepseek-r1" "openrouter")))
      (should (= (plist-get fields :context-window) 131072))
      (should (= (plist-get fields :max-output) 8192))
      (should (equal (plist-get fields :reasoning-efforts) '("low" "medium" "high")))
      (let ((ann (kargu-model-annotation-string "deepseek/deepseek-r1" "openrouter")))
        (should (string-match-p "131k ctx" ann))
        (should (string-match-p "max 8k" ann))
        (should (string-match-p "🧠 think: low..high" ann))
        (should (string-match-p "\\$0.55/1M" ann))))
    (let ((fields (kargu-model-read "qwen/qwen-2.5-vl-72b-instruct:free" "openrouter")))
      (should (= (plist-get fields :context-window) 32768))
      (should (plist-get fields :vision))
      (should (plist-get fields :free))
      (let ((ann (kargu-model-annotation-string "qwen/qwen-2.5-vl-72b-instruct:free" "openrouter")))
        (should (string-match-p "32k ctx" ann))
        (should (string-match-p "👁 vision" ann))
        (should (string-match-p "⚡ free" ann))))))

(ert-deftest kargu-dynamic-models-ollama-schema-test ()
  "Test parsing Ollama /api/tags schema with details and parameter sizes."
  (let (
        (ollama-json
         '((("name" . "llama3.3:70b")
            ("details" . ((("parameter_size" . "70.6B")
                           ("quantization_level" . "Q4_K_M")
                           ("family" . "llama")))))
           (("name" . "deepseek-r1:32b")
            ("details" . ((("parameter_size" . "32.8B")
                           ("quantization_level" . "Q4_K_M"))))))))
    (kargu-test-publish-model-catalog ollama-json "ollama")
    (let ((llama (kargu-model-read "llama3.3:70b" "ollama"))
          (r1 (kargu-model-read "deepseek-r1:32b" "ollama")))
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
  (let (
        (gemini-json
         '((("name" . "models/gemini-1.5-pro")
            ("inputTokenLimit" . 2097152)
            ("outputTokenLimit" . 8192)
            ("description" . "Mid-size multimodal model"))
           (("name" . "models/gemini-2.0-flash")
            ("inputTokenLimit" . 1048576)
            ("outputTokenLimit" . 8192)
            ("description" . "Fast next-gen model")))))
    (kargu-test-publish-model-catalog gemini-json "google")
    (let ((pro (kargu-model-read "gemini-1.5-pro" "google"))
          (flash (kargu-model-read "gemini-2.0-flash" "google")))
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
  ;; Header generation is native; the editor captures raw overrides only.
  (let ((intent (kargu-api-auth-intent "test-secret" "test-provider-custom")))
    (should (equal (kargu-aget intent "key") "test-secret"))
    (should (equal (cdr (assoc "X-Custom-Header" (kargu-aget intent "extra_headers"))) "CustomVal"))))

(ert-deftest kargu-provider-catalog-endpoints-test ()
  "Test that provider endpoints are dynamic and no hallucinated models are statically registered."
  (let ((opencode-models (kargu-provider-models "opencode")))
    ;; Static models should not exist
    (should-not opencode-models)
    (should (equal (kargu-provider-models-api "opencode") "https://opencode.ai/zen/v1/models"))
    (should (equal (kargu-provider-usage-api "opencode") "https://opencode.ai/zen/v1/user"))))

(provide 'tests/test-dynamic-models)
;;; test-dynamic-models.el ends here
