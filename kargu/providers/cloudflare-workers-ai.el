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
 :models-api "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/models"
 :env '("CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/cloudflare-workers-ai)

;;; cloudflare-workers-ai.el ends here
