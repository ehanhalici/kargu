;;; kargu/providers/nebius.el --- Nebius Token Factory provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Nebius Token Factory (nebius).

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
 :id "nebius"
 :name "Nebius Token Factory"
 :api "https://api.tokenfactory.nebius.com/v1"
 :env '("NEBIUS_API_KEY")
 :models '("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2.5-fast" "moonshotai/Kimi-K2.5" "google/gemma-3-27b-it" "Qwen/Qwen3-Next-80B-A3B-Thinking-fast" "Qwen/Qwen2.5-VL-72B-Instruct" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3.5-397B-A17B-fast" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-Next-80B-A3B-Thinking" "Qwen/Qwen3-235B-A22B-Instruct-2507" "Qwen/Qwen3-32B" "Qwen/Qwen3-235B-A22B-Thinking-2507-fast" "openai/gpt-oss-120b-fast")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nebius)

;;; nebius.el ends here
