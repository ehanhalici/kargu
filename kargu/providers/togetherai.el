;;; kargu/providers/togetherai.el --- Together AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Together AI (togetherai).

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
 :id "togetherai"
 :name "Together AI"
 :api "https://api.together.xyz/v1"
 :env '("TOGETHER_API_KEY")
 :models '("meta-llama/Llama-3.3-70B-Instruct-Turbo" "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo" "LiquidAI/LFM2-24B-A2B" "meta-llama/Meta-Llama-3-8B-Instruct-Lite" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "google/gemma-3n-E4B-it" "Qwen/Qwen3.7-Max" "Qwen/Qwen3.6-Plus" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3-Coder-Next-FP8" "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8" "Qwen/Qwen3-235B-A22B-Instruct-2507-tput")
 :npm "@ai-sdk/togetherai")

(provide 'kargu/providers/togetherai)

;;; togetherai.el ends here
