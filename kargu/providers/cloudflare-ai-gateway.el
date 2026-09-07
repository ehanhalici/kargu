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
 :models-api "https://gateway.ai.cloudflare.com/v1/${CLOUDFLARE_ACCOUNT_ID}/${CLOUDFLARE_GATEWAY_ID}/models"
 :env '("CLOUDFLARE_API_TOKEN" "CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_GATEWAY_ID")
 :npm "ai-gateway-provider")

(provide 'kargu/providers/cloudflare-ai-gateway)

;;; cloudflare-ai-gateway.el ends here
