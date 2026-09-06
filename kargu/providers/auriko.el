;;; kargu/providers/auriko.el --- Auriko provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Auriko (auriko).

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
 :id "auriko"
 :name "Auriko"
 :api "https://api.auriko.ai/v1"
 :env '("AURIKO_API_KEY")
 :models '("deepseek-v4-flash" "gemini-2.5-pro" "grok-4.3" "gemini-2.5-flash" "glm-5.1" "deepseek-v4-pro" "claude-opus-4-7" "minimax-m2-7-highspeed" "minimax-m2-7" "qwen-3.6-plus" "kimi-k2.5" "kimi-k2.6" "gemini-3.1-pro-preview" "claude-opus-4-6" "claude-sonnet-4-6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/auriko)

;;; auriko.el ends here
