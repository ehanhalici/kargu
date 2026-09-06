;;; kargu/providers/helicone.el --- Helicone provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Helicone (helicone).

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
 :id "helicone"
 :name "Helicone"
 :api "https://ai-gateway.helicone.ai/v1"
 :env '("HELICONE_API_KEY")
 :models '("chatgpt-4o-latest" "gpt-4.1-mini-2025-04-14" "deepseek-v3.1-terminus" "claude-3.5-haiku" "llama-3.1-8b-instruct" "o3" "llama-prompt-guard-2-86m" "qwen3-coder-30b-a3b-instruct" "hermes-2-pro-llama-3-8b" "deepseek-v3" "grok-code-fast-1" "o1-mini" "deepseek-r1-distill-llama-70b" "qwen3-32b" "claude-sonnet-4")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/helicone)

;;; helicone.el ends here
