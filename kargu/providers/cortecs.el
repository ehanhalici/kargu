;;; kargu/providers/cortecs.el --- Cortecs provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Cortecs (cortecs).

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
 :id "cortecs"
 :name "Cortecs"
 :api "https://api.cortecs.ai/v1"
 :env '("CORTECS_API_KEY")
 :models '("deepseek-r1-0528" "deepseek-v4-flash" "minimax-m2.5" "deepseek-v3-0324" "claude-opus4-7" "glm-4.7" "qwen3-235b-a22b-instruct-2507" "qwen3-coder-30b-a3b-instruct" "minimax-m2.1" "qwen3-32b" "claude-4-6-sonnet" "claude-sonnet-4" "llama-4-maverick" "gemini-2.5-pro" "claude-4-5-sonnet")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/cortecs)

;;; cortecs.el ends here
