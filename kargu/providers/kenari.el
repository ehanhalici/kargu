;;; kargu/providers/kenari.el --- Kenari provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Kenari (kenari).

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
 :id "kenari"
 :name "Kenari"
 :api "https://kenari.id/v1"
 :env '("KENARI_API_KEY")
 :models '("deepseek-v4-flash" "kimi-k2-6" "glm-5-1" "gemma-4-31b-it" "grok-4-3" "qwen3-7-plus" "kimi-k2-7-code" "deepseek-v4-pro" "deepseek-v4-flash:free" "claude-opus-4-7" "minimax-m3" "claude-opus-4-8" "gpt-5-4-mini" "mimo-v2-5" "gpt-oss-120b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/kenari)

;;; kenari.el ends here
