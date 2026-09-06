;;; kargu/providers/ollama-cloud.el --- Ollama Cloud provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Ollama Cloud (ollama-cloud).

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
 :id "ollama-cloud"
 :name "Ollama Cloud"
 :api "https://ollama.com/v1"
 :env '("OLLAMA_API_KEY")
 :models '("deepseek-v4-flash" "minimax-m2.5" "devstral-small-2:24b" "glm-4.7" "cogito-2.1:671b" "minimax-m2.1" "gpt-oss:120b" "nemotron-3-nano:30b" "ministral-3:8b" "rnj-1:8b" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-4.6" "kimi-k2-thinking")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/ollama-cloud)

;;; ollama-cloud.el ends here
