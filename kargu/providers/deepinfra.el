;;; kargu/providers/deepinfra.el --- Deep Infra provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Deep Infra (deepinfra).

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
 :id "deepinfra"
 :name "Deep Infra"
 :api "https://api.deepinfra.com/v1/openai"
 :env '("DEEPINFRA_API_KEY")
 :models '("meta-llama/Meta-Llama-3.1-70B-Instruct" "meta-llama/Meta-Llama-3.1-8B-Instruct" "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" "meta-llama/Llama-4-Scout-17B-16E-Instruct" "meta-llama/Llama-3.3-70B-Instruct-Turbo" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.7-Max" "Qwen/Qwen3.6-27B" "Qwen/Qwen3-Next-80B-A3B-Instruct" "Qwen/Qwen3-Max")
 :npm "@ai-sdk/deepinfra")

(provide 'kargu/providers/deepinfra)

;;; deepinfra.el ends here
