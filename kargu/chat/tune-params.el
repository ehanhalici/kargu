;;; kargu/chat/tune-params.el --- Transient UI for provider JSON parameters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Transient tab and sub-menus for tuning OpenAPI / provider-specific JSON
;; parameters, supporting multiple formats:
;; - OpenAPI standard (Vivgrid, OpenAI, DeepSeek, Groq, etc.)
;; - OpenRouter routing (sort, zdr, order, quantizations, etc.)
;; - Anthropic Messages API (extended thinking, thinking budget, top-k)
;; - Google Gemini API (generationConfig, thinkingConfig, safety settings)
;; - Ollama / Local runners (num_ctx, repeat_penalty, etc.)
;;
;; All user interactions, docstrings, and labels are in English.

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
(require 'kargu/providers/params)

(eval-and-compile
  (require 'transient nil t))

(declare-function kargu--provider-name "kargu/core")
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt")
(declare-function kargu-tune-openrouter-menu "kargu/chat/tune-params")
(declare-function kargu-tune-openapi-menu "kargu/chat/tune-params")
(declare-function kargu-tune-anthropic-menu "kargu/chat/tune-params")
(declare-function kargu-tune-gemini-menu "kargu/chat/tune-params")
(declare-function kargu-tune-ollama-menu "kargu/chat/tune-params")

;;;; Formatters & Descriptions ---------------------------------------------

(defun kargu-tune--format-bool (val)
  "Format boolean VAL (t, :json-false, nil) for display."
  (cond
   ((eq val t) (propertize "ON (true)" 'face 'font-lock-doc-face))
   ((eq val :json-false) (propertize "OFF (false)" 'face 'font-lock-warning-face))
   (t (propertize "default (omit)" 'face 'font-lock-comment-face))))

;; OpenRouter Descriptions
(defun kargu-tune--param-sort-desc ()
  "Formatted description for sort parameter."
  (let ((val (kargu-provider-param-get "sort")))
    (format "Sort Strategy:     %s"
            (if val
                (propertize (upcase (format "%s" val)) 'face 'font-lock-keyword-face)
              (propertize "default (load balance)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-data-collection-desc ()
  "Formatted description for data collection parameter."
  (let ((val (kargu-provider-param-get "data_collection")))
    (format "Data Collection:   %s"
            (if val
                (propertize (upcase (format "%s" val))
                            'face (if (equal val "deny") 'font-lock-doc-face 'font-lock-warning-face))
              (propertize "allow (default)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-quantizations-desc ()
  "Formatted description for quantizations parameter."
  (let ((val (kargu-provider-param-get "quantizations")))
    (format "Quantizations:     %s"
            (if val
                (propertize (format "%S" (if (vectorp val) (append val nil) val))
                            'face 'font-lock-string-face)
              (propertize "all (no filter)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-allow-fallbacks-desc ()
  "Formatted description for allow_fallbacks parameter."
  (format "Allow Fallbacks:   %s"
          (kargu-tune--format-bool (kargu-provider-param-get "allow_fallbacks"))))

(defun kargu-tune--param-require-parameters-desc ()
  "Formatted description for require_parameters parameter."
  (format "Require Params:    %s"
          (kargu-tune--format-bool (kargu-provider-param-get "require_parameters"))))

(defun kargu-tune--param-zdr-desc ()
  "Formatted description for zero data retention parameter."
  (format "Zero Data Retention: %s"
          (kargu-tune--format-bool (kargu-provider-param-get "zdr"))))

(defun kargu-tune--param-distillable-desc ()
  "Formatted description for distillable text parameter."
  (format "Distillable Text:  %s"
          (kargu-tune--format-bool (kargu-provider-param-get "enforce_distillable_text"))))

(defun kargu-tune--param-order-desc ()
  "Formatted description for provider order parameter."
  (let ((val (kargu-provider-param-get "order")))
    (format "Provider Order:    %s"
            (if val
                (propertize (if (vectorp val) (mapconcat #'identity val ", ") (format "%s" val))
                            'face 'font-lock-variable-name-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-only-desc ()
  "Formatted description for provider whitelist parameter."
  (let ((val (kargu-provider-param-get "only")))
    (format "Only Providers:    %s"
            (if val
                (propertize (if (vectorp val) (mapconcat #'identity val ", ") (format "%s" val))
                            'face 'font-lock-variable-name-face)
              (propertize "none (all allowed)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-ignore-desc ()
  "Formatted description for provider blacklist parameter."
  (let ((val (kargu-provider-param-get "ignore")))
    (format "Ignore Providers:  %s"
            (if val
                (propertize (if (vectorp val) (mapconcat #'identity val ", ") (format "%s" val))
                            'face 'font-lock-warning-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-throughput-desc ()
  "Formatted description for minimum throughput parameter."
  (let ((val (kargu-provider-param-get "preferred_min_throughput")))
    (format "Min Throughput:    %s"
            (if val
                (propertize (format "%s TPS" val) 'face 'font-lock-constant-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-latency-desc ()
  "Formatted description for maximum latency parameter."
  (let ((val (kargu-provider-param-get "preferred_max_latency")))
    (format "Max Latency:       %s"
            (if val
                (propertize (format "%s s" val) 'face 'font-lock-constant-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

;; OpenAPI / Universal Descriptions
(defun kargu-tune--param-tier-desc ()
  "Formatted description for service_tier parameter."
  (let ((val (kargu-provider-param-get "service_tier")))
    (format "Service Tier:      %s"
            (if val
                (propertize (upcase (format "%s" val)) 'face 'font-lock-keyword-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-seed-desc ()
  "Formatted description for seed parameter."
  (let ((val (kargu-provider-param-get "seed")))
    (format "Random Seed:       %s"
            (if val
                (propertize (format "%d" val) 'face 'font-lock-constant-face)
              (propertize "nil (random)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-top-p-desc ()
  "Formatted description for top_p parameter."
  (let ((val (kargu-provider-param-get "top_p")))
    (format "Top P:             %s"
            (if val
                (propertize (format "%.2f" val) 'face 'font-lock-constant-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-parallel-tools-desc ()
  "Formatted description for parallel_tool_calls parameter."
  (format "Parallel Tools:    %s"
          (kargu-tune--format-bool (kargu-provider-param-get "parallel_tool_calls"))))

(defun kargu-tune--param-penalties-desc ()
  "Formatted description for frequency and presence penalties."
  (let ((freq (kargu-provider-param-get "frequency_penalty"))
        (pres (kargu-provider-param-get "presence_penalty")))
    (format "Penalties (f/p):   %s / %s"
            (if freq (format "%.2f" freq) "0.0")
            (if pres (format "%.2f" pres) "0.0"))))

(defun kargu-tune--param-user-desc ()
  "Formatted description for user tracking parameter."
  (let ((val (kargu-provider-param-get "user")))
    (format "End-User ID:       %s"
            (if val
                (propertize (format "%s" val) 'face 'font-lock-variable-name-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

;; Anthropic Descriptions
(defun kargu-tune--param-extended-thinking-desc ()
  "Formatted description for extended_thinking parameter."
  (format "Extended Thinking: %s"
          (kargu-tune--format-bool (kargu-provider-param-get "extended_thinking"))))

(defun kargu-tune--param-thinking-budget-desc ()
  "Formatted description for thinking_budget parameter."
  (let ((val (kargu-provider-param-get "thinking_budget")))
    (format "Thinking Budget:   %s"
            (if val
                (propertize (format "%d tokens" val) 'face 'font-lock-keyword-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-top-k-desc ()
  "Formatted description for top_k parameter."
  (let ((val (kargu-provider-param-get "top_k")))
    (format "Top K:             %s"
            (if val
                (propertize (format "%d" val) 'face 'font-lock-constant-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-anthropic-beta-desc ()
  "Formatted description for anthropic_beta parameter."
  (let ((val (kargu-provider-param-get "anthropic_beta")))
    (format "Beta Flags:        %s"
            (if val
                (propertize (if (vectorp val) (mapconcat #'identity val ", ") (format "%s" val))
                            'face 'font-lock-string-face)
              (propertize "none" 'face 'font-lock-comment-face)))))

;; Gemini Descriptions
(defun kargu-tune--param-mime-type-desc ()
  "Formatted description for response_mime_type parameter."
  (let ((val (kargu-provider-param-get "response_mime_type")))
    (format "Response MIME:     %s"
            (if val
                (propertize (format "%s" val) 'face 'font-lock-string-face)
              (propertize "text/plain (default)" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-safety-desc ()
  "Formatted description for safety_threshold parameter."
  (let ((val (kargu-provider-param-get "safety_threshold")))
    (format "Safety Threshold:  %s"
            (if val
                (propertize (format "%s" val) 'face 'font-lock-warning-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

;; Ollama Descriptions
(defun kargu-tune--param-num-ctx-desc ()
  "Formatted description for num_ctx parameter."
  (let ((val (kargu-provider-param-get "num_ctx")))
    (format "Context (num_ctx): %s"
            (if val
                (propertize (format "%d tokens" val) 'face 'font-lock-constant-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

(defun kargu-tune--param-repeat-penalty-desc ()
  "Formatted description for repeat_penalty parameter."
  (let ((val (kargu-provider-param-get "repeat_penalty")))
    (format "Repeat Penalty:    %s"
            (if val
                (propertize (format "%.2f" val) 'face 'font-lock-constant-face)
              (propertize "default" 'face 'font-lock-comment-face)))))

;; Universal Custom Body Description
(defun kargu-tune--param-custom-body-desc ()
  "Formatted description for custom body parameter."
  (let ((val (kargu-provider-param-get "custom_body")))
    (format "Custom JSON Body:  %s"
            (if val
                (propertize (truncate-string-to-width (format "%S" val) 30 0 nil "...")
                            'face 'font-lock-string-face)
              (propertize "empty" 'face 'font-lock-comment-face)))))

(defun kargu-tune--provider-params-summary-desc ()
  "Summary description of configured provider parameters for kargu-tune-menu."
  (let* ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter"))
         (fmt (kargu-provider-format-type pname))
         (params (kargu-provider-params-get-all pname))
         (active-count (length params)))
    (format "More Parameters:   %s"
            (cond
             ((null fmt)
              (propertize (format "[%s: unsupported]" pname) 'face 'font-lock-comment-face))
             ((> active-count 0)
              (let* ((keys (mapconcat #'car (cl-subseq params 0 (min 3 active-count)) ", "))
                     (summary (if (> active-count 3) (format "%s +%d" keys (- active-count 3)) keys)))
                (propertize (format "[%s (%s): %s active (%s)]" pname fmt active-count summary)
                            'face 'font-lock-keyword-face)))
             (t
              (propertize (format "[%s (%s): defaults]" pname fmt) 'face 'font-lock-comment-face))))))

;;;; Interactive Parameter Setters -----------------------------------------

;; OpenRouter Setters
(defun kargu-tune-param-cycle-sort ()
  "Cycle sort strategy for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "sort")))
    (message "kargu: sort strategy: %s" (or next "default (load balance)"))))

(defun kargu-tune-param-cycle-data-collection ()
  "Cycle data collection policy for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "data_collection")))
    (message "kargu: data collection: %s" (or next "allow (default)"))))

(defun kargu-tune-param-toggle-allow-fallbacks ()
  "Toggle allow_fallbacks for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "allow_fallbacks")))
    (message "kargu: allow_fallbacks: %S" next)))

(defun kargu-tune-param-toggle-require-parameters ()
  "Toggle require_parameters for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "require_parameters")))
    (message "kargu: require_parameters: %S" next)))

(defun kargu-tune-param-toggle-zdr ()
  "Toggle zero data retention (ZDR) for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "zdr")))
    (message "kargu: zero data retention (zdr): %S" next)))

(defun kargu-tune-param-toggle-enforce-distillable-text ()
  "Toggle enforce_distillable_text for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "enforce_distillable_text")))
    (message "kargu: enforce_distillable_text: %S" next)))

(defun kargu-tune-param-select-quantizations ()
  "Select allowed quantizations via comma-separated input."
  (interactive)
  (let* ((curr (kargu-provider-param-get "quantizations"))
         (curr-str (if curr (mapconcat #'identity (if (vectorp curr) (append curr nil) curr) ",") ""))
         (input (read-string "Quantizations (comma-separated, e.g. fp16,bf16, empty to clear): " curr-str))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "quantizations" nil)
          (message "kargu: quantizations cleared (all allowed)"))
      (let ((parsed (kargu--parse-string-list-input trimmed)))
        (kargu-provider-param-set "quantizations" parsed)
        (message "kargu: quantizations set to: %S" parsed)))))

(defun kargu-tune-param-set-order ()
  "Set prioritized provider order (comma-separated provider slugs)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "order"))
         (curr-str (if curr (mapconcat #'identity (if (vectorp curr) (append curr nil) curr) ",") ""))
         (input (read-string "Provider Order (e.g. Anthropic,Together, empty to clear): " curr-str))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "order" nil)
          (message "kargu: provider order cleared"))
      (let ((parsed (kargu--parse-string-list-input trimmed)))
        (kargu-provider-param-set "order" parsed)
        (message "kargu: provider order set to: %S" parsed)))))

(defun kargu-tune-param-set-only ()
  "Set whitelist of allowed providers (comma-separated slugs)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "only"))
         (curr-str (if curr (mapconcat #'identity (if (vectorp curr) (append curr nil) curr) ",") ""))
         (input (read-string "Only Providers (whitelist, empty to clear): " curr-str))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "only" nil)
          (message "kargu: only providers whitelist cleared"))
      (let ((parsed (kargu--parse-string-list-input trimmed)))
        (kargu-provider-param-set "only" parsed)
        (message "kargu: only providers set to: %S" parsed)))))

(defun kargu-tune-param-set-ignore ()
  "Set blacklist of ignored providers (comma-separated slugs)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "ignore"))
         (curr-str (if curr (mapconcat #'identity (if (vectorp curr) (append curr nil) curr) ",") ""))
         (input (read-string "Ignore Providers (blacklist, empty to clear): " curr-str))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "ignore" nil)
          (message "kargu: ignore providers blacklist cleared"))
      (let ((parsed (kargu--parse-string-list-input trimmed)))
        (kargu-provider-param-set "ignore" parsed)
        (message "kargu: ignore providers set to: %S" parsed)))))

(defun kargu-tune-param-set-min-throughput ()
  "Set minimum throughput threshold in tokens per second."
  (interactive)
  (let* ((curr (kargu-provider-param-get "preferred_min_throughput"))
         (input (read-string "Min Throughput (tokens/sec, e.g. 30, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "preferred_min_throughput" nil)
          (message "kargu: min throughput cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "preferred_min_throughput" num)
        (message "kargu: min throughput set to: %s TPS" num)))))

(defun kargu-tune-param-set-max-latency ()
  "Set maximum latency threshold in seconds."
  (interactive)
  (let* ((curr (kargu-provider-param-get "preferred_max_latency"))
         (input (read-string "Max Latency (seconds to first token, e.g. 1.5, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "preferred_max_latency" nil)
          (message "kargu: max latency cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "preferred_max_latency" num)
        (message "kargu: max latency set to: %s s" num)))))

;; OpenAPI / Universal Setters
(defun kargu-tune-param-cycle-service-tier ()
  "Cycle service tier for active provider."
  (interactive)
  (let ((next (kargu-provider-param-toggle "service_tier")))
    (message "kargu: service tier: %s" (or next "default"))))

(defun kargu-tune-param-set-seed ()
  "Set deterministic sampling integer seed."
  (interactive)
  (let* ((curr (kargu-provider-param-get "seed"))
         (input (read-string "Random Seed (integer, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "seed" nil)
          (message "kargu: seed cleared (random)"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "seed" num)
        (message "kargu: seed set to: %d" num)))))

(defun kargu-tune-param-set-top-p ()
  "Set nucleus sampling top-p threshold (0.0 to 1.0)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "top_p"))
         (input (read-string "Top P (0.0 to 1.0, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "top_p" nil)
          (message "kargu: top_p cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "top_p" num)
        (message "kargu: top_p set to: %.2f" num)))))

(defun kargu-tune-param-set-frequency-penalty ()
  "Set frequency penalty (-2.0 to 2.0)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "frequency_penalty"))
         (input (read-string "Frequency Penalty (-2.0 to 2.0, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "frequency_penalty" nil)
          (message "kargu: frequency penalty cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "frequency_penalty" num)
        (message "kargu: frequency penalty set to: %.2f" num)))))

(defun kargu-tune-param-set-presence-penalty ()
  "Set presence penalty (-2.0 to 2.0)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "presence_penalty"))
         (input (read-string "Presence Penalty (-2.0 to 2.0, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "presence_penalty" nil)
          (message "kargu: presence penalty cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "presence_penalty" num)
        (message "kargu: presence penalty set to: %.2f" num)))))

(defun kargu-tune-param-toggle-parallel-tool-calls ()
  "Toggle parallel tool calls flag."
  (interactive)
  (let ((next (kargu-provider-param-toggle "parallel_tool_calls")))
    (message "kargu: parallel_tool_calls: %S" next)))

(defun kargu-tune-param-set-user ()
  "Set end-user identifier for abuse tracking."
  (interactive)
  (let* ((curr (kargu-provider-param-get "user"))
         (input (read-string "End-User ID (empty to clear): "
                             (if curr (format "%s" curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "user" nil)
          (message "kargu: end-user ID cleared"))
      (kargu-provider-param-set "user" trimmed)
      (message "kargu: end-user ID set to: %s" trimmed))))

;; Anthropic & Gemini Setters
(defun kargu-tune-param-toggle-extended-thinking ()
  "Toggle extended thinking mode (Anthropic)."
  (interactive)
  (let ((next (kargu-provider-param-toggle "extended_thinking")))
    (message "kargu: extended thinking: %S" next)))

(defun kargu-tune-param-set-thinking-budget ()
  "Set thinking token budget (Anthropic / Gemini)."
  (interactive)
  (let* ((curr (kargu-provider-param-get "thinking_budget"))
         (input (read-string "Thinking token budget (e.g. 2048, 4096, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "thinking_budget" nil)
          (message "kargu: thinking budget cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "thinking_budget" num)
        (message "kargu: thinking budget set to: %d tokens" num)))))

(defun kargu-tune-param-set-top-k ()
  "Set top-k sampling pool threshold."
  (interactive)
  (let* ((curr (kargu-provider-param-get "top_k"))
         (input (read-string "Top K (integer, e.g. 20, 40, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "top_k" nil)
          (message "kargu: top_k cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "top_k" num)
        (message "kargu: top_k set to: %d" num)))))

(defun kargu-tune-param-cycle-safety-threshold ()
  "Cycle safety threshold level for Google Gemini models."
  (interactive)
  (let ((next (kargu-provider-param-toggle "safety_threshold")))
    (message "kargu: safety threshold: %s" (or next "default"))))

(defun kargu-tune-param-cycle-response-mime-type ()
  "Cycle response MIME type for Google Gemini models."
  (interactive)
  (let ((next (kargu-provider-param-toggle "response_mime_type")))
    (message "kargu: response MIME type: %s" (or next "text/plain (default)"))))

;; Ollama Setters
(defun kargu-tune-param-set-num-ctx ()
  "Set context window size (num_ctx) for local runner."
  (interactive)
  (let* ((curr (kargu-provider-param-get "num_ctx"))
         (input (read-string "Context size in tokens (num_ctx, e.g. 8192, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "num_ctx" nil)
          (message "kargu: num_ctx cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "num_ctx" num)
        (message "kargu: num_ctx set to: %d" num)))))

(defun kargu-tune-param-set-repeat-penalty ()
  "Set repeat penalty for local runner."
  (interactive)
  (let* ((curr (kargu-provider-param-get "repeat_penalty"))
         (input (read-string "Repeat penalty (e.g. 1.1, empty to clear): "
                             (if curr (number-to-string curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "repeat_penalty" nil)
          (message "kargu: repeat penalty cleared"))
      (let ((num (string-to-number trimmed)))
        (kargu-provider-param-set "repeat_penalty" num)
        (message "kargu: repeat penalty set to: %.2f" num)))))

;; Universal Actions
(defun kargu-tune-param-set-custom-body ()
  "Input arbitrary JSON to merge into the request body."
  (interactive)
  (let* ((curr (kargu-provider-param-get "custom_body"))
         (input (read-string "Custom JSON Body (e.g. {\"seed\": 42}, empty to clear): "
                             (if curr (kargu--json-encode curr) "")))
         (trimmed (string-trim input)))
    (if (string-empty-p trimmed)
        (progn
          (kargu-provider-param-set "custom_body" nil)
          (message "kargu: custom JSON body cleared"))
      (condition-case err
          (let ((decoded (kargu--json-decode-object trimmed)))
            (kargu-provider-param-set "custom_body" decoded)
            (message "kargu: custom JSON body set: %S" decoded))
        (error (user-error "Invalid JSON: %s" (error-message-string err)))))))

(defun kargu-tune-param-preview-json ()
  "Display preview of compiled provider JSON parameters in a popup buffer."
  (interactive)
  (let* ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter"))
         (payload (kargu-provider-params-build-payload pname))
         (encoded (if payload (kargu--json-encode payload) "{}"))
         (buf (get-buffer-create "*kargu-params-preview*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (format "// Compiled JSON Payload Extra Parameters for %s:\n\n" pname))
      (insert encoded)
      (insert "\n")
      (goto-char (point-min))
      (read-only-mode 1)
      (display-buffer buf))
    (message "Compiled parameters for %s previewed" pname)))

(defun kargu-tune-param-reset ()
  "Reset all parameters for active provider to defaults."
  (interactive)
  (let ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter")))
    (kargu-provider-params-reset pname)
    (message "kargu: reset all parameters for %s" pname)))

;;;; Transient Prefixes per Format ----------------------------------------

(when (fboundp 'transient-define-prefix)

  ;; 1. OpenRouter Menu
  (transient-define-prefix kargu-tune-openrouter-menu ()
    "Control panel for OpenRouter routing and custom JSON parameters."
    [:description (lambda ()
                    (let ((p (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openrouter")))
                      (format "%s (OpenRouter Routing Architecture)" (propertize (upcase p) 'face 'bold))))
     ["Static Routing & Policies"
      ("s" kargu-tune-param-cycle-sort :description kargu-tune--param-sort-desc :transient t)
      ("d" kargu-tune-param-cycle-data-collection :description kargu-tune--param-data-collection-desc :transient t)
      ("Q" "Quantizations Filter" kargu-tune-param-select-quantizations :description kargu-tune--param-quantizations-desc :transient t)]
     ["Guarantees & Flags"
      ("f" kargu-tune-param-toggle-allow-fallbacks :description kargu-tune--param-allow-fallbacks-desc :transient t)
      ("p" kargu-tune-param-toggle-require-parameters :description kargu-tune--param-require-parameters-desc :transient t)
      ("z" kargu-tune-param-toggle-zdr :description kargu-tune--param-zdr-desc :transient t)
      ("t" kargu-tune-param-toggle-enforce-distillable-text :description kargu-tune--param-distillable-desc :transient t)]]
    [["Dynamic Routing Lists"
      ("o" "Provider Order" kargu-tune-param-set-order :description kargu-tune--param-order-desc :transient t)
      ("x" "Only Providers" kargu-tune-param-set-only :description kargu-tune--param-only-desc :transient t)
      ("i" "Ignore Providers" kargu-tune-param-set-ignore :description kargu-tune--param-ignore-desc :transient t)]
     ["Thresholds & Custom Body"
      ("m" "Min Throughput (TPS)" kargu-tune-param-set-min-throughput :description kargu-tune--param-throughput-desc :transient t)
      ("l" "Max Latency (TTFT)" kargu-tune-param-set-max-latency :description kargu-tune--param-latency-desc :transient t)
      ("b" "Custom JSON Body" kargu-tune-param-set-custom-body :description kargu-tune--param-custom-body-desc :transient t)]]
    [["Actions"
      ("j" "Preview JSON Payload" kargu-tune-param-preview-json :transient t)
      ("R" "Reset Parameters" kargu-tune-param-reset :transient t)
      ("q" "Back / Quit" transient-quit-one)]])

  ;; 2. Universal OpenAPI Menu (Vivgrid, OpenAI, DeepSeek, Groq, Cerebras, etc.)
  (transient-define-prefix kargu-tune-openapi-menu ()
    "Control panel for Universal OpenAPI standard parameters."
    [:description (lambda ()
                    (let ((p (if (fboundp 'kargu--provider-name) (kargu--provider-name) "openai")))
                      (format "%s (Universal OpenAPI Standard)" (propertize (upcase p) 'face 'bold))))
     ["Sampling & Determinism"
      ("s" "Random Seed" kargu-tune-param-set-seed :description kargu-tune--param-seed-desc :transient t)
      ("p" "Top P" kargu-tune-param-set-top-p :description kargu-tune--param-top-p-desc :transient t)
      ("F" "Frequency Penalty" kargu-tune-param-set-frequency-penalty :description kargu-tune--param-penalties-desc :transient t)
      ("P" "Presence Penalty" kargu-tune-param-set-presence-penalty :description (lambda () "") :transient t)]
     ["Tier & Execution Features"
      ("t" kargu-tune-param-cycle-service-tier :description kargu-tune--param-tier-desc :transient t)
      ("T" kargu-tune-param-toggle-parallel-tool-calls :description kargu-tune--param-parallel-tools-desc :transient t)
      ("u" "End-User ID" kargu-tune-param-set-user :description kargu-tune--param-user-desc :transient t)
      ("b" "Custom JSON Body" kargu-tune-param-set-custom-body :description kargu-tune--param-custom-body-desc :transient t)]]
    [["Actions"
      ("j" "Preview JSON Payload" kargu-tune-param-preview-json :transient t)
      ("R" "Reset Parameters" kargu-tune-param-reset :transient t)
      ("q" "Back / Quit" transient-quit-one)]])

  ;; 3. Anthropic Menu
  (transient-define-prefix kargu-tune-anthropic-menu ()
    "Control panel for Anthropic Messages API parameters."
    [:description (lambda ()
                    (let ((p (if (fboundp 'kargu--provider-name) (kargu--provider-name) "anthropic")))
                      (format "%s (Anthropic Messages API)" (propertize (upcase p) 'face 'bold))))
     ["Extended Thinking"
      ("e" kargu-tune-param-toggle-extended-thinking :description kargu-tune--param-extended-thinking-desc :transient t)
      ("b" "Thinking Budget" kargu-tune-param-set-thinking-budget :description kargu-tune--param-thinking-budget-desc :transient t)]
     ["Sampling & Options"
      ("k" "Top K" kargu-tune-param-set-top-k :description kargu-tune--param-top-k-desc :transient t)
      ("p" "Top P" kargu-tune-param-set-top-p :description kargu-tune--param-top-p-desc :transient t)
      ("u" "Metadata User ID" kargu-tune-param-set-user :description kargu-tune--param-user-desc :transient t)
      ("B" "Custom JSON Body" kargu-tune-param-set-custom-body :description kargu-tune--param-custom-body-desc :transient t)]]
    [["Actions"
      ("j" "Preview JSON Payload" kargu-tune-param-preview-json :transient t)
      ("R" "Reset Parameters" kargu-tune-param-reset :transient t)
      ("q" "Back / Quit" transient-quit-one)]])

  ;; 4. Google Gemini Menu
  (transient-define-prefix kargu-tune-gemini-menu ()
    "Control panel for Google Gemini GenerateContent API parameters."
    [:description (lambda ()
                    (let ((p (if (fboundp 'kargu--provider-name) (kargu--provider-name) "google")))
                      (format "%s (Google Gemini API)" (propertize (upcase p) 'face 'bold))))
     ["Thinking & Sampling"
      ("b" "Thinking Budget" kargu-tune-param-set-thinking-budget :description kargu-tune--param-thinking-budget-desc :transient t)
      ("p" "Top P" kargu-tune-param-set-top-p :description kargu-tune--param-top-p-desc :transient t)
      ("k" "Top K" kargu-tune-param-set-top-k :description kargu-tune--param-top-k-desc :transient t)]
     ["Config & Safety"
      ("m" kargu-tune-param-cycle-response-mime-type :description kargu-tune--param-mime-type-desc :transient t)
      ("s" kargu-tune-param-cycle-safety-threshold :description kargu-tune--param-safety-desc :transient t)
      ("B" "Custom JSON Body" kargu-tune-param-set-custom-body :description kargu-tune--param-custom-body-desc :transient t)]]
    [["Actions"
      ("j" "Preview JSON Payload" kargu-tune-param-preview-json :transient t)
      ("R" "Reset Parameters" kargu-tune-param-reset :transient t)
      ("q" "Back / Quit" transient-quit-one)]])

  ;; 5. Ollama / Local Runner Menu
  (transient-define-prefix kargu-tune-ollama-menu ()
    "Control panel for Ollama / Local Runner options."
    [:description (lambda ()
                    (let ((p (if (fboundp 'kargu--provider-name) (kargu--provider-name) "ollama")))
                      (format "%s (Local Runner Options)" (propertize (upcase p) 'face 'bold))))
     ["Context & Sampling Options"
      ("c" "Context Size (num_ctx)" kargu-tune-param-set-num-ctx :description kargu-tune--param-num-ctx-desc :transient t)
      ("r" "Repeat Penalty" kargu-tune-param-set-repeat-penalty :description kargu-tune--param-repeat-penalty-desc :transient t)
      ("p" "Top P" kargu-tune-param-set-top-p :description kargu-tune--param-top-p-desc :transient t)
      ("k" "Top K" kargu-tune-param-set-top-k :description kargu-tune--param-top-k-desc :transient t)
      ("b" "Custom JSON Body" kargu-tune-param-set-custom-body :description kargu-tune--param-custom-body-desc :transient t)]]
    [["Actions"
      ("j" "Preview JSON Payload" kargu-tune-param-preview-json :transient t)
      ("R" "Reset Parameters" kargu-tune-param-reset :transient t)
      ("q" "Back / Quit" transient-quit-one)]]))

;;;; Dynamic Menu Dispatcher ----------------------------------------------

(defun kargu-tune-provider-params-menu ()
  "Open format-specific parameters transient menu based on active provider."
  (interactive)
  (let* ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "default"))
         (fmt (kargu-provider-format-type pname)))
    (if (null fmt)
        (message "kargu: Parameter tuning is not supported yet for provider '%s'" pname)
      (pcase fmt
        ('openrouter (call-interactively #'kargu-tune-openrouter-menu))
        ('anthropic (call-interactively #'kargu-tune-anthropic-menu))
        ('gemini (call-interactively #'kargu-tune-gemini-menu))
        ('ollama (call-interactively #'kargu-tune-ollama-menu))
        ('openapi (call-interactively #'kargu-tune-openapi-menu))
        (_ (call-interactively #'kargu-tune-openapi-menu))))))

(provide 'kargu/chat/tune-params)

;;; tune-params.el ends here
