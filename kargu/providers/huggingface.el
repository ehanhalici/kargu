;;; kargu/providers/huggingface.el --- Hugging Face provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Hugging Face (huggingface).

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
 :id "huggingface"
 :name "Hugging Face"
 :api "https://router.huggingface.co/v1"
 :env '("HF_TOKEN")
 :models '("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2-Instruct-0905" "moonshotai/Kimi-K2-Instruct" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "stepfun-ai/Step-3.5-Flash" "stepfun-ai/Step-3.7-Flash" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3-Coder-Next" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3.6-27B")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/huggingface)

;;; huggingface.el ends here
