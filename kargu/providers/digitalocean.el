;;; kargu/providers/digitalocean.el --- DigitalOcean provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for DigitalOcean (digitalocean).

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
 :id "digitalocean"
 :name "DigitalOcean"
 :api "https://inference.do-ai.run/v1"
 :env '("DIGITALOCEAN_ACCESS_TOKEN")
 :models '("anthropic-claude-haiku-4.5" "openai-gpt-image-1" "e5-large-v2" "bge-m3" "mistral-3-14B" "nemotron-3-ultra-550b" "minimax-m2.5" "openai-gpt-5.4-nano" "deepseek-v3" "openai-gpt-image-2" "openai-gpt-5.2" "deepseek-r1-distill-llama-70b" "qwen3-embedding-0.6b" "gemma-4-31B-it" "llama-4-maverick")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/digitalocean)

;;; digitalocean.el ends here
