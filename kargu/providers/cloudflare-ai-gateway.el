;;; kargu/providers/cloudflare-ai-gateway.el --- Cloudflare AI Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Cloudflare AI Gateway (cloudflare-ai-gateway).

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
 :id "cloudflare-ai-gateway"
 :name "Cloudflare AI Gateway"
 :api "https://gateway.ai.cloudflare.com/v1/${CLOUDFLARE_ACCOUNT_ID}/${CLOUDFLARE_GATEWAY_ID}"
 :env '("CLOUDFLARE_API_TOKEN" "CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_GATEWAY_ID")
 :models '("workers-ai/@cf/baai/bge-m3" "workers-ai/@cf/baai/bge-small-en-v1.5" "workers-ai/@cf/baai/bge-reranker-base" "workers-ai/@cf/baai/bge-base-en-v1.5" "workers-ai/@cf/baai/bge-large-en-v1.5" "workers-ai/@cf/ai4bharat/indictrans2-en-indic-1B" "workers-ai/@cf/ibm-granite/granite-4.0-h-micro" "workers-ai/@cf/huggingface/distilbert-sst-2-int8" "workers-ai/@cf/moonshotai/kimi-k2.5" "workers-ai/@cf/moonshotai/kimi-k2.6" "workers-ai/@cf/mistral/mistral-7b-instruct-v0.1" "workers-ai/@cf/google/gemma-3-12b-it" "workers-ai/@cf/myshell-ai/melotts" "workers-ai/@cf/openai/gpt-oss-120b" "workers-ai/@cf/openai/gpt-oss-20b")
 :npm "ai-gateway-provider")

(provide 'kargu/providers/cloudflare-ai-gateway)

;;; cloudflare-ai-gateway.el ends here
