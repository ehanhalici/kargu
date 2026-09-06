;;; kargu/providers/jiekou.el --- Jiekou.AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Jiekou.AI (jiekou).

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
 :id "jiekou"
 :name "Jiekou.AI"
 :api "https://api.jiekou.ai/openai"
 :env '("JIEKOU_API_KEY")
 :models '("o3" "grok-code-fast-1" "gpt-5.2-pro" "gemini-2.5-pro" "claude-haiku-4-5-20251001" "gpt-5-pro" "gemini-2.5-flash" "o4-mini" "gemini-2.5-flash-lite-preview-09-2025" "claude-opus-4-1-20250805" "grok-4-1-fast-non-reasoning" "gpt-5-chat-latest" "claude-opus-4-5-20251101" "gpt-5.1-codex" "gpt-5.1-codex-max")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/jiekou)

;;; jiekou.el ends here
