;;; kargu/providers/wandb.el --- Weights & Biases provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Weights & Biases (wandb).

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
 :id "wandb"
 :name "Weights & Biases"
 :api "https://api.inference.wandb.ai/v1"
 :env '("WANDB_API_KEY")
 :models '("ibm-granite/granite-4.1-8b" "meta-llama/Llama-3.3-70B-Instruct" "meta-llama/Llama-3.1-70B-Instruct" "meta-llama/Llama-3.1-8B-Instruct" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "microsoft/Phi-4-mini-instruct" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.6-27B" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct" "Qwen/Qwen3.5-27B" "Qwen/Qwen3-30B-A3B-Instruct-2507")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/wandb)

;;; wandb.el ends here
