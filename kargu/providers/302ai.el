;;; kargu/providers/302ai.el --- 302.AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for 302.AI (302ai).

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
 :id "302ai"
 :name "302.AI"
 :api "https://api.302.ai/v1"
 :env '("302AI_API_KEY")
 :models '("gpt-5.4-mini-2026-03-17" "chatgpt-4o-latest" "gpt-5.4-nano-2026-03-17" "kimi-k2-0905-preview" "grok-4.20-beta-0309-non-reasoning" "gemini-2.5-flash-nothink" "qwen-plus" "glm-4.7" "qwen3-235b-a22b-instruct-2507" "glm-4.5v" "claude-opus-4-5" "gemini-2.5-pro" "gpt-5" "claude-haiku-4-5-20251001" "kimi-k2-thinking-turbo")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/302ai)

;;; 302ai.el ends here
