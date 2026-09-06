;;; kargu/providers/abacus.el --- Abacus provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Abacus (abacus).

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
 :id "abacus"
 :name "Abacus"
 :api "https://routellm.abacus.ai/v1"
 :env '("ABACUS_API_KEY")
 :models '("o3" "gemini-3.1-flash-lite" "route-llm" "grok-code-fast-1" "gpt-5.3-codex-xhigh" "llama-3.3-70b-versatile" "gemini-2.5-pro" "gpt-5" "claude-haiku-4-5-20251001" "grok-4.3" "gemini-2.5-flash" "gpt-4o" "o4-mini" "qwen3-max" "gemini-3.5-flash")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/abacus)

;;; abacus.el ends here
