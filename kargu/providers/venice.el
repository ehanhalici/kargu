;;; kargu/providers/venice.el --- Venice AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Venice AI (venice).

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
 :id "venice"
 :name "Venice AI"
 :api "https://api.venice.ai/api/v1"
 :env '("VENICE_API_KEY")
 :models '("llama-3.3-70b" "deepseek-r1-llama-70b" "z-ai-glm-5-turbo" "grok-4-20-multi-agent" "deepseek-v4-flash" "google-gemma-4-31b-it" "kimi-k2-6" "openai-gpt-56-terra-pro" "qwen3-235b-a22b-instruct-2507" "openai-gpt-56-sol-pro" "nvidia-nemotron-cascade-2-30b-a3b" "claude-opus-4-7-fast" "openai-gpt-55-pro" "qwen3-5-397b-a17b" "claude-opus-4-5")
 :npm "venice-ai-sdk-provider")

(provide 'kargu/providers/venice)

;;; venice.el ends here
