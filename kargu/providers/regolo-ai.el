;;; kargu/providers/regolo-ai.el --- Regolo AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Regolo AI (regolo-ai).

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
 :id "regolo-ai"
 :name "Regolo AI"
 :api "https://api.regolo.ai/v1"
 :env '("REGOLO_API_KEY")
 :models '("llama-3.1-8b-instruct" "minimax-m2.5" "mistral-small3.2" "qwen3-reranker-4b" "qwen3-embedding-8b" "llama-3.3-70b-instruct" "qwen-image" "qwen3.5-122b" "gpt-oss-120b" "qwen3-coder-next" "qwen3.5-9b" "mistral-small-4-119b" "gpt-oss-20b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/regolo-ai)

;;; regolo-ai.el ends here
