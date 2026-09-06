;;; kargu/providers/opencode-go.el --- OpenCode Go provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenCode Go (opencode-go).

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
 :id "opencode-go"
 :name "OpenCode Go"
 :api "https://opencode.ai/zen/go/v1"
 :env '("OPENCODE_API_KEY")
 :models '("deepseek-v4-flash" "minimax-m2.5" "qwen3.7-plus" "qwen3.7-max" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-5.2" "minimax-m3" "qwen3.5-plus" "minimax-m2.7" "kimi-k2.5" "mimo-v2.5" "mimo-v2-omni" "kimi-k2.6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/opencode-go)

;;; opencode-go.el ends here
