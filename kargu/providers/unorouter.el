;;; kargu/providers/unorouter.el --- UnoRouter provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for UnoRouter (unorouter).

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
 :id "unorouter"
 :name "UnoRouter"
 :api "https://api.unorouter.com/v1"
 :env '("UNOROUTER_API_KEY")
 :models '("gpt-5.5:free" "deepseek-v4-flash" "gpt-5.4:free" "glm-4.5-flash:free" "minimax-m2.7:free" "step-3.7-flash:free" "claude-haiku-4-5-20251001" "qwen3.5-397b-a17b:free" "nemotron-3-ultra-550b-a55b:free" "gemini-3.5-flash" "deepseek-v4-pro" "deepseek-v4-flash:free" "claude-sonnet-5" "glm-5.2" "claude-opus-4-8")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/unorouter)

;;; unorouter.el ends here
