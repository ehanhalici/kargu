;;; kargu/providers/chutes.el --- Chutes provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Chutes (chutes).

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
 :id "chutes"
 :name "Chutes"
 :api "https://llm.chutes.ai/v1"
 :env '("CHUTES_API_KEY")
 :models '("moonshotai/Kimi-K2.6-TEE" "moonshotai/Kimi-K2.5-TEE" "google/gemma-4-31B-turbo-TEE" "Qwen/Qwen3-32B-TEE" "Qwen/Qwen3.6-27B-TEE" "Qwen/Qwen3-235B-A22B-Thinking-2507-TEE" "Qwen/Qwen3.5-397B-A17B-TEE" "unsloth/Mistral-Nemo-Instruct-2407-TEE" "zai-org/GLM-5-TEE" "zai-org/GLM-5.1-TEE" "zai-org/GLM-5.2-TEE" "deepseek-ai/DeepSeek-V3.2-TEE" "MiniMaxAI/MiniMax-M2.5-TEE")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/chutes)

;;; chutes.el ends here
