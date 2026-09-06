;;; kargu/providers/cloudflare-workers-ai.el --- Cloudflare Workers AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Cloudflare Workers AI (cloudflare-workers-ai).

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
 :id "cloudflare-workers-ai"
 :name "Cloudflare Workers AI"
 :api "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1"
 :env '("CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_API_KEY")
 :models '("@cf/ibm-granite/granite-4.0-h-micro" "@cf/moonshotai/kimi-k2.7-code" "@cf/moonshotai/kimi-k2.6" "@cf/google/gemma-4-26b-a4b-it" "@cf/openai/gpt-oss-120b" "@cf/openai/gpt-oss-20b" "@cf/mistralai/mistral-small-3.1-24b-instruct" "@cf/nvidia/nemotron-3-120b-a12b" "@cf/zai-org/glm-5.2" "@cf/zai-org/glm-4.7-flash" "@cf/deepseek-ai/deepseek-r1-distill-qwen-32b" "@cf/qwen/qwen3-30b-a3b-fp8" "@cf/qwen/qwen2.5-coder-32b-instruct" "@cf/qwen/qwq-32b" "@cf/meta/llama-3.2-1b-instruct")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/cloudflare-workers-ai)

;;; cloudflare-workers-ai.el ends here
