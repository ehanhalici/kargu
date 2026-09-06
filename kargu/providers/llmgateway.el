;;; kargu/providers/llmgateway.el --- LLM Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for LLM Gateway (llmgateway).

;;; Code:

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

(require 'kargu/providers/registry)

(kargu-register-provider
 :id "llmgateway"
 :name "LLM Gateway"
 :api "https://api.llmgateway.io/v1"
 :env '("LLMGATEWAY_API_KEY")
 :models '("qwen-coder-plus" "mistral-large-latest" "qwen3-vl-235b-a22b-thinking" "devstral-small-2507" "qwen3-vl-30b-a3b-thinking" "deepseek-v4-flash" "qwen3-coder-plus" "minimax-m2.7-highspeed" "qwen-plus" "o3" "nemotron-3-ultra-550b" "minimax-m2.5" "grok-4-20-beta-0309-non-reasoning" "glm-4.7" "gemini-3.1-flash-lite")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/llmgateway)

;;; llmgateway.el ends here
