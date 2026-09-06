;;; kargu/providers/opencode.el --- OpenCode Zen provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenCode Zen (opencode).

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
 :id "opencode"
 :name "OpenCode Zen"
 :api "https://opencode.ai/zen/v1"
 :env '("OPENCODE_API_KEY")
 :models '("ring-2.6-1t-free" "mimo-v2-pro-free" "deepseek-v4-flash" "minimax-m2.5" "glm-4.7" "mimo-v2.5-free" "kimi-k2" "minimax-m2.1" "nemotron-3-ultra-free" "glm-4.7-free" "gemini-3-flash" "deepseek-v4-flash-free" "claude-sonnet-4" "claude-opus-4-5" "gpt-5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/opencode)

;;; opencode.el ends here
