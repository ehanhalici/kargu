;;; kargu/providers/params.el --- Extensible JSON parameters for LLM providers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provides schema registration, storage, cycling/toggling, and request
;; payload assembly for provider-specific and OpenAPI JSON parameters.
;;
;; Supports multiple format profiles:
;; - `openrouter': Routing blocks under "provider": { ... }
;; - `openapi': Universal OpenAPI standard (Vivgrid, OpenAI, DeepSeek, Groq, etc.)
;; - `anthropic': Messages API format (thinking, metadata, top_k)
;; - `gemini': Google GenerateContent format (generationConfig, safetySettings)
;; - `ollama': Local runner format (options: { num_ctx, repeat_penalty, ... })
;;
;; All user interactions, docstrings, and variable documentation are in English.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(require 'kargu/core)
(require 'kargu/json)

(declare-function kargu--provider-name "kargu/core")
(declare-function kargu-provider-get "kargu/providers/registry" (id))

;;;; Predefined Format Constants -------------------------------------------

(defconst kargu-openrouter-sort-options
  '("price" "throughput" "latency")
  "OpenRouter provider sorting strategy options.")

(defconst kargu-openrouter-data-collection-options
  '("deny" "allow")
  "OpenRouter data collection policy options.")

(defconst kargu-openrouter-quantization-options
  '("fp16" "bf16" "fp8" "int8" "mxfp8" "fp4" "mxfp4" "nvfp4" "int4" "fp32" "fp6" "unknown")
  "OpenRouter model quantization filter options.")

(defconst kargu-openrouter-reasoning-efforts
  '("none" "minimal" "low" "medium" "high")
  "Reasoning depth levels for reasoning models.")

(defconst kargu-openapi-service-tier-options
  '("auto" "default" "flex" "scale" "priority")
  "Service tier options for OpenAPI-compliant providers.")

(defconst kargu-gemini-mime-type-options
  '("text/plain" "application/json")
  "Response MIME type options for Google Gemini models.")

(defconst kargu-gemini-safety-threshold-options
  '("BLOCK_NONE" "BLOCK_ONLY_HIGH" "BLOCK_MEDIUM_AND_ABOVE" "BLOCK_LOW_AND_ABOVE")
  "Safety threshold levels for Google Gemini models.")

;;;; Schemas & Session Store -----------------------------------------------

(defvar kargu-provider-params--schemas (make-hash-table :test 'equal)
  "Hash table mapping schema ID strings to schema definition plists.")

(defvar kargu--session-provider-params nil
  "Session-local alist mapping provider ID to ((KEY . VALUE) ...).")

(defun kargu--normalize-provider-id (provider)
  "Normalize PROVIDER to a lowercase string."
  (downcase (string-trim (if (symbolp provider) (symbol-name provider) (format "%s" (or provider "default"))))))

(defun kargu-provider-format-type (provider)
  "Return format profile symbol for PROVIDER as declared in `catalog.el'.
Returns `openrouter', `anthropic', `gemini', `ollama', `openapi',
or nil if unsupported."
  (let* ((pid (kargu--normalize-provider-id provider)))
    (if (fboundp 'kargu-provider-format)
        (kargu-provider-format pid)
      (let ((info (and (fboundp 'kargu-provider-get) (kargu-provider-get pid))))
        (and info (plist-get info :format))))))

(defun kargu-register-provider-params (&rest plist)
  "Register a parameter schema for a provider or format profile.
PLIST accepts:
  :provider     String or symbol ID (e.g. \"openrouter\", \"anthropic\", \"openapi\").
  :target-block Optional default target block string (e.g. \"provider\").
  :specs        List of parameter spec plists, each having:
                `:key', `:label', `:type' (`enum', `boolean', `multi-enum',
                `string-list', `number', `json'), `:choices', `:target',
                `:default', `:doc'."
  (let* ((p (plist-get plist :provider))
         (pid (cond ((stringp p) (downcase (string-trim p)))
                    ((symbolp p) (downcase (symbol-name p)))
                    (t (error "Provider must be a string or symbol: %S" p))))
         (target-block (plist-get plist :target-block))
         (specs (plist-get plist :specs)))
    (puthash pid
             (list :provider pid
                   :target-block target-block
                   :specs specs)
             kargu-provider-params--schemas)
    pid))

(defun kargu-provider-params-schema (provider)
  "Return schema plist for PROVIDER, falling back to its format profile or default."
  (when provider
    (let* ((p (kargu--normalize-provider-id provider))
           (fmt-sym (kargu-provider-format-type p))
           (fmt (and fmt-sym (symbol-name fmt-sym))))
      (or (gethash p kargu-provider-params--schemas)
          (and fmt (gethash fmt kargu-provider-params--schemas))
          nil))))

(defun kargu-provider-params-specs (provider)
  "Return list of parameter spec plists for PROVIDER."
  (let ((schema (kargu-provider-params-schema provider)))
    (and schema (plist-get schema :specs))))

(defun kargu-provider-params-find-spec (key &optional provider)
  "Return spec plist for KEY in PROVIDER."
  (let* ((p (or provider (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter")))
         (specs (kargu-provider-params-specs p))
         (k-str (if (symbolp key) (symbol-name key) (format "%s" key))))
    (cl-find-if (lambda (s) (equal (plist-get s :key) k-str)) specs)))

;;;; Storage Accessors -----------------------------------------------------

(defun kargu-provider-params-get-all (&optional provider)
  "Return alist of ((KEY . VALUE) ...) for PROVIDER."
  (let* ((pid (kargu--normalize-provider-id (or provider (if (fboundp 'kargu--provider-name)
                                                             (kargu--provider-name)
                                                           "openrouter"))))
         (session-entry (assoc pid kargu--session-provider-params))
         (custom-entry (and (boundp 'kargu-provider-parameters)
                            (assoc pid kargu-provider-parameters))))
    (cond
     (session-entry (cdr session-entry))
     (custom-entry (cdr custom-entry))
     (t nil))))

(defun kargu-provider-param-get (key &optional provider)
  "Get value of parameter KEY for PROVIDER."
  (let* ((k-str (if (symbolp key) (symbol-name key) (format "%s" key)))
         (params (kargu-provider-params-get-all provider))
         (cell (assoc k-str params)))
    (if cell
        (cdr cell)
      (let ((spec (kargu-provider-params-find-spec key provider)))
        (and spec (plist-get spec :default))))))

(defun kargu-provider-param-set (key value &optional provider)
  "Set parameter KEY to VALUE for PROVIDER in session store.
If VALUE is nil, the key is removed from custom overrides."
  (let* ((pid (kargu--normalize-provider-id (or provider (if (fboundp 'kargu--provider-name)
                                                             (kargu--provider-name)
                                                           "openrouter"))))
         (k-str (if (symbolp key) (symbol-name key) (format "%s" key)))
         (current-all (copy-alist (or (cdr (assoc pid kargu--session-provider-params))
                                      (and (boundp 'kargu-provider-parameters)
                                           (cdr (assoc pid kargu-provider-parameters)))
                                      nil)))
         (filtered (assoc-delete-all k-str current-all #'equal)))
    (when (not (null value))
      (push (cons k-str value) filtered))
    (setq kargu--session-provider-params
          (cons (cons pid filtered)
                (assoc-delete-all pid kargu--session-provider-params #'equal)))
    value))

(defun kargu-provider-params-reset (&optional provider)
  "Reset all custom parameters for PROVIDER to nil."
  (let ((pid (kargu--normalize-provider-id (or provider (if (fboundp 'kargu--provider-name)
                                                            (kargu--provider-name)
                                                          "openrouter")))))
    (setq kargu--session-provider-params
          (assoc-delete-all pid kargu--session-provider-params #'equal))
    (message "kargu: reset parameters for %s" pid)))

;;;; Interactive Helpers (Cycle & Toggle) ----------------------------------

(defun kargu-provider-param-toggle (key &optional provider)
  "Toggle or cycle value of KEY for PROVIDER.
Booleans cycle: nil -> t -> :json-false -> nil.
Enums cycle: nil -> choice1 -> choice2 ... -> nil.
Returns the new value."
  (let* ((spec (kargu-provider-params-find-spec key provider))
         (type (and spec (plist-get spec :type)))
         (curr (kargu-provider-param-get key provider)))
    (cond
     ((eq type 'boolean)
      (let ((next (cond ((null curr) t)
                        ((eq curr t) :json-false)
                        (t nil))))
        (kargu-provider-param-set key next provider)
        next))
     ((eq type 'enum)
      (let* ((choices (plist-get spec :choices))
             (next (cond
                    ((null curr) (car choices))
                    ((member curr choices)
                     (let ((tail (cdr (member curr choices))))
                       (if tail (car tail) nil)))
                    (t (car choices)))))
        (kargu-provider-param-set key next provider)
        next))
     (t
      (error "Cannot automatically toggle non-boolean/enum parameter: %s" key)))))

;;;; Payload Assembly ------------------------------------------------------

(defun kargu--parse-string-list-input (input)
  "Parse comma-separated string INPUT into a vector of trimmed non-empty strings.
If INPUT is already a list or vector, returns a vector of strings."
  (cond
   ((vectorp input) input)
   ((listp input) (vconcat (mapcar (lambda (x) (string-trim (format "%s" x))) input)))
   ((stringp input)
    (let* ((parts (split-string input "," t "[ \t\r\n]+"))
           (trimmed (cl-remove-if #'string-empty-p parts)))
      (if trimmed (vconcat trimmed) nil)))
   (t nil)))

(defun kargu-provider-params-build-payload (&optional provider)
  "Build payload alist for PROVIDER to merge into chat-completions request.
Separates parameters targeting sub-objects (such as OpenRouter's
\"provider\": { ... }, Gemini's \"generationConfig\": { ... },
Anthropic's \"thinking\": { ... }, or Ollama's \"options\": { ... })
from top-level request parameters."
  (let* ((p (or provider (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter")))
         (pid (kargu--normalize-provider-id p))
         (fmt (kargu-provider-format-type pid))
         (schema (kargu-provider-params-schema pid))
         (default-target (and schema (plist-get schema :target-block)))
         (params (kargu-provider-params-get-all pid))
         (sub-blocks (make-hash-table :test 'equal))
         (top-level nil))
    (dolist (entry params)
      (let* ((key (car entry))
             (val (cdr entry)))
        (when (and val (not (eq val :omit)))
          (let* ((spec (kargu-provider-params-find-spec key pid))
                 (type (and spec (plist-get spec :type)))
                 (target (or (and spec (plist-get spec :target))
                             default-target
                             :top-level))
                 ;; Format value for JSON serialization
                 (json-val
                  (cond
                   ((eq val :json-false) :json-false)
                   ((eq val t) t)
                   ((eq type 'string-list) (kargu--parse-string-list-input val))
                   ((eq type 'multi-enum)
                    (cond ((vectorp val) val)
                          ((listp val) (vconcat val))
                          ((stringp val) (kargu--parse-string-list-input val))
                          (t val)))
                   ((and (eq type 'json) (stringp val))
                    (condition-case _
                        (kargu--json-decode-object val)
                      (error val)))
                   ((and (equal key "custom_body") (stringp val))
                    (condition-case _
                        (kargu--json-decode-object val)
                      (error nil)))
                   (t val))))
            (when json-val
              (if (and (equal key "custom_body") (consp json-val))
                  ;; Merge custom body entries into top-level
                  (setq top-level (append top-level json-val))
                (if (and target (not (eq target :top-level)))
                    (let* ((t-str (if (symbolp target) (symbol-name target) (format "%s" target)))
                           (existing (gethash t-str sub-blocks)))
                      (puthash t-str (append existing (list (cons key json-val))) sub-blocks))
                  (push (cons key json-val) top-level))))))))

    ;; Format-specific post-processing
    (cond
     ;; Anthropic format special handling
     ((eq fmt 'anthropic)
      (let ((ext-thinking (kargu-provider-param-get "extended_thinking" pid))
            (budget (kargu-provider-param-get "thinking_budget" pid))
            (user-id (kargu-provider-param-get "user_id" pid)))
        (when (or (eq ext-thinking t) (and (numberp budget) (> budget 0)))
          (push (cons "thinking" `(("type" . "enabled")
                                   ("budget_tokens" . ,(or budget 2048))))
                top-level))
        (when (eq ext-thinking :json-false)
          (push (cons "thinking" '(("type" . "disabled"))) top-level))
        (when (and user-id (not (string-empty-p (format "%s" user-id))))
          (push (cons "metadata" `(("user_id" . ,user-id))) top-level))))

     ;; Gemini format special handling
     ((eq fmt 'gemini)
      (let ((budget (kargu-provider-param-get "thinking_budget" pid))
            (safety (kargu-provider-param-get "safety_threshold" pid))
            (raw-gen (gethash "generationConfig" sub-blocks))
            (gen-cfg nil))
        (dolist (cell raw-gen)
          (let ((k (car cell))
                (v (cdr cell)))
            (push (cons (cond ((equal k "top_p") "topP")
                              ((equal k "top_k") "topK")
                              ((equal k "candidate_count") "candidateCount")
                              ((equal k "response_mime_type") "responseMimeType")
                              (t k))
                        v)
                  gen-cfg)))
        (setq gen-cfg (reverse gen-cfg))
        (when (and (numberp budget) (> budget 0))
          (setq gen-cfg (append gen-cfg `(("thinkingConfig" . (("thinkingBudget" . ,budget)))))))
        (when gen-cfg
          (puthash "generationConfig" gen-cfg sub-blocks))
        (when safety
          (push (cons "safetySettings"
                      (vconcat
                       (mapcar (lambda (cat)
                                 `(("category" . ,cat)
                                   ("threshold" . ,safety)))
                               '("HARM_CATEGORY_HARASSMENT"
                                 "HARM_CATEGORY_HATE_SPEECH"
                                 "HARM_CATEGORY_SEXUALLY_EXPLICIT"
                                 "HARM_CATEGORY_DANGEROUS_CONTENT"))))
                top-level)))))

    ;; Convert sub-blocks hash table into payload alists
    (maphash (lambda (block-name entries)
               (when entries
                 (push (cons block-name entries) top-level)))
             sub-blocks)
    top-level))

;;;; Built-in Schema Registrations -----------------------------------------

;; 1. OpenRouter Routing Schema
(kargu-register-provider-params
 :provider "openrouter"
 :target-block "provider"
 :specs
 (list
  ;; Static Enums
  (list :key "sort" :label "Sort Strategy" :type 'enum
        :choices kargu-openrouter-sort-options
        :doc "Prioritize lowest price, highest throughput, or lowest latency.")
  (list :key "data_collection" :label "Data Collection" :type 'enum
        :choices kargu-openrouter-data-collection-options
        :doc "Deny endpoints that store or train on user prompts.")
  (list :key "quantizations" :label "Quantizations" :type 'multi-enum
        :choices kargu-openrouter-quantization-options
        :doc "Filter out low-precision quantizations to prevent quality loss.")
  (list :key "reasoning_effort" :label "Reasoning Effort" :type 'enum
        :choices kargu-openrouter-reasoning-efforts
        :doc "Reasoning depth for OpenRouter reasoning models.")
  ;; Static Booleans (Tri-state: true, false, omit/default)
  (list :key "allow_fallbacks" :label "Allow Fallbacks" :type 'boolean
        :doc "Whether to allow routing fallbacks to subsequent providers on error.")
  (list :key "require_parameters" :label "Require Parameters" :type 'boolean
        :doc "Only route to providers supporting all request parameters (critical for tools).")
  (list :key "zdr" :label "Zero Data Retention (ZDR)" :type 'boolean
        :doc "Route only to endpoints committing to zero data retention.")
  (list :key "enforce_distillable_text" :label "Distillable Text" :type 'boolean
        :doc "Only select providers allowing model distillation on outputs.")
  ;; Dynamic String Lists
  (list :key "order" :label "Provider Order" :type 'string-list
        :doc "List of provider slugs in order of priority (e.g. Anthropic, Together).")
  (list :key "only" :label "Only Providers" :type 'string-list
        :doc "Whitelist of provider slugs to restrict routing to.")
  (list :key "ignore" :label "Ignore Providers" :type 'string-list
        :doc "Blacklist of provider slugs to exclude from routing.")
  ;; Dynamic Thresholds & JSON
  (list :key "preferred_min_throughput" :label "Min Throughput (TPS)" :type 'number
        :doc "Minimum tokens per second required.")
  (list :key "preferred_max_latency" :label "Max Latency (TTFT)" :type 'number
        :doc "Maximum time to first token (seconds).")
  (list :key "max_price" :label "Max Price Cap" :type 'json
        :doc "Price limit object or prompt/completion rate.")
  (list :key "custom_body" :label "Custom JSON Body" :type 'json :target :top-level
        :doc "Arbitrary JSON to merge directly into the root request body.")))

;; 2. Universal OpenAPI Standard Schema (Vivgrid, OpenAI, DeepSeek, Groq, Cerebras, etc.)
(kargu-register-provider-params
 :provider "openapi"
 :specs
 (list
  (list :key "service_tier" :label "Service Tier" :type 'enum
        :choices kargu-openapi-service-tier-options :target :top-level
        :doc "Service tier for request execution (e.g. auto, default, flex, scale).")
  (list :key "seed" :label "Random Seed" :type 'number :target :top-level
        :doc "Integer seed for deterministic sampling.")
  (list :key "top_p" :label "Top P" :type 'number :target :top-level
        :doc "Nucleus sampling probability threshold (0.0 to 1.0).")
  (list :key "frequency_penalty" :label "Frequency Penalty" :type 'number :target :top-level
        :doc "Penalize new tokens based on their frequency in text (-2.0 to 2.0).")
  (list :key "presence_penalty" :label "Presence Penalty" :type 'number :target :top-level
        :doc "Penalize new tokens based on whether they appear in text (-2.0 to 2.0).")
  (list :key "parallel_tool_calls" :label "Parallel Tool Calls" :type 'boolean :target :top-level
        :doc "Whether to enable parallel function calling.")
  (list :key "user" :label "End-User ID" :type 'string :target :top-level
        :doc "Unique identifier representing your end-user for abuse monitoring.")
  (list :key "custom_body" :label "Custom JSON Body" :type 'json :target :top-level
        :doc "Arbitrary JSON to merge directly into the root request body.")))

;; Alias "default" to openapi
(kargu-register-provider-params
 :provider "default"
 :specs (kargu-provider-params-specs "openapi"))

;; 3. Anthropic Messages API Schema
(kargu-register-provider-params
 :provider "anthropic"
 :specs
 (list
  (list :key "extended_thinking" :label "Extended Thinking" :type 'boolean :target :top-level
        :doc "Enable Claude thinking / reasoning mode.")
  (list :key "thinking_budget" :label "Thinking Budget" :type 'number :target :top-level
        :doc "Maximum tokens allocated for reasoning process (e.g. 2048, 4096, 8192).")
  (list :key "top_k" :label "Top K" :type 'number :target :top-level
        :doc "Only sample from the top K options for each subsequent token.")
  (list :key "top_p" :label "Top P" :type 'number :target :top-level
        :doc "Nucleus sampling threshold (0.0 to 1.0).")
  (list :key "anthropic_beta" :label "Anthropic Beta Flags" :type 'string-list :target :top-level
        :doc "Beta features (e.g. prompt-caching-2024-07-31, output-128k-2025-02-19).")
  (list :key "user_id" :label "User ID (Metadata)" :type 'string :target :top-level
        :doc "External user identifier for safety tracking.")
  (list :key "custom_body" :label "Custom JSON Body" :type 'json :target :top-level
        :doc "Arbitrary JSON to merge directly into the root request body.")))

;; 4. Google Gemini GenerateContent API Schema
(kargu-register-provider-params
 :provider "gemini"
 :target-block "generationConfig"
 :specs
 (list
  (list :key "thinking_budget" :label "Thinking Budget" :type 'number :target :top-level
        :doc "Thinking token budget for Gemini 2.0 / 2.5 Flash Thinking.")
  (list :key "top_p" :label "Top P" :type 'number :target "generationConfig"
        :doc "Nucleus sampling threshold.")
  (list :key "top_k" :label "Top K" :type 'number :target "generationConfig"
        :doc "Top-K sampling threshold.")
  (list :key "candidate_count" :label "Candidate Count" :type 'number :target "generationConfig"
        :doc "Number of response candidates to generate.")
  (list :key "response_mime_type" :label "Response MIME Type" :type 'enum
        :choices kargu-gemini-mime-type-options :target "generationConfig"
        :doc "Output MIME type (text/plain or application/json).")
  (list :key "safety_threshold" :label "Safety Threshold" :type 'enum
        :choices kargu-gemini-safety-threshold-options :target :top-level
        :doc "Block threshold for safety filters.")
  (list :key "custom_body" :label "Custom JSON Body" :type 'json :target :top-level
        :doc "Arbitrary JSON to merge directly into the root request body.")))

;; 5. Ollama / Local Runner Schema
(kargu-register-provider-params
 :provider "ollama"
 :target-block "options"
 :specs
 (list
  (list :key "num_ctx" :label "Context Size (num_ctx)" :type 'number :target "options"
        :doc "Context window size in tokens (e.g. 4096, 8192, 32768).")
  (list :key "repeat_penalty" :label "Repeat Penalty" :type 'number :target "options"
        :doc "Penalize repetitive token generation (e.g. 1.1).")
  (list :key "top_k" :label "Top K" :type 'number :target "options"
        :doc "Top-K sampling pool.")
  (list :key "top_p" :label "Top P" :type 'number :target "options"
        :doc "Top-P nucleus sampling threshold.")
  (list :key "num_thread" :label "CPU Threads" :type 'number :target "options"
        :doc "Number of CPU threads to allocate.")
  (list :key "custom_body" :label "Custom JSON Body" :type 'json :target :top-level
        :doc "Arbitrary JSON to merge directly into the root request body.")))

(provide 'kargu/providers/params)

;;; params.el ends here
