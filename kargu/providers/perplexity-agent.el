;;; kargu/providers/perplexity-agent.el --- Perplexity Agent provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Perplexity Agent (perplexity-agent).

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
 :id "perplexity-agent"
 :name "Perplexity Agent"
 :api "https://api.perplexity.ai/v1"
 :env '("PERPLEXITY_API_KEY")
 :models '("xai/grok-4-1-fast-non-reasoning" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.1-pro-preview" "google/gemini-3-flash-preview" "openai/gpt-5.2" "openai/gpt-5.4" "openai/gpt-5-mini" "openai/gpt-5.1" "openai/gpt-5.5" "nvidia/nemotron-3-super-120b-a12b" "anthropic/claude-opus-4-5" "anthropic/claude-sonnet-4-5" "anthropic/claude-opus-4-7" "anthropic/claude-haiku-4-5")
 :npm "@ai-sdk/openai")

(provide 'kargu/providers/perplexity-agent)

;;; perplexity-agent.el ends here
