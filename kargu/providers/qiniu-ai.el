;;; kargu/providers/qiniu-ai.el --- Qiniu provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Qiniu (qiniu-ai).

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
 :id "qiniu-ai"
 :name "Qiniu"
 :api "https://api.qnaigc.com/v1"
 :env '("QINIU_API_KEY")
 :models '("deepseek-r1-0528" "doubao-1.5-thinking-pro" "qwen3-vl-30b-a3b-thinking" "claude-3.5-haiku" "deepseek-v3-0324" "qwen3-235b-a22b-instruct-2507" "deepseek-v3" "kimi-k2" "qwen3-32b" "qwen3-max-preview" "claude-3.5-sonnet" "qwen3-next-80b-a3b-instruct" "gemini-2.5-pro" "claude-4.5-haiku" "kling-v2-6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/qiniu-ai)

;;; qiniu-ai.el ends here
