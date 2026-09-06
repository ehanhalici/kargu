;;; kargu/providers/novita-ai.el --- NovitaAI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for NovitaAI (novita-ai).

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
 :id "novita-ai"
 :name "NovitaAI"
 :api "https://api.novita.ai/openai"
 :env '("NOVITA_API_KEY")
 :models '("inclusionai/ling-2.6-1t" "inclusionai/ring-2.6-1t" "inclusionai/ling-2.6-flash" "meta-llama/llama-3.1-8b-instruct" "meta-llama/llama-3-70b-instruct" "meta-llama/llama-4-scout-17b-16e-instruct" "meta-llama/llama-3.3-70b-instruct" "meta-llama/llama-3-8b-instruct" "meta-llama/llama-3.2-3b-instruct" "meta-llama/llama-4-maverick-17b-128e-instruct-fp8" "moonshotai/kimi-k2-instruct" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2-0905")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/novita-ai)

;;; novita-ai.el ends here
