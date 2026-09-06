;;; kargu/providers/merge-gateway.el --- Merge Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Merge Gateway (merge-gateway).

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
 :id "merge-gateway"
 :name "Merge Gateway"
 :api "https://ai.mergegateway.com/v1"
 :env '("MERGE_GATEWAY_API_KEY")
 :models '("xai/grok-4.3" "xai/grok-4.20-0309-reasoning" "moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2.7-code-highspeed" "mistral/codestral-latest" "mistral/mistral-large-latest" "mistral/devstral-small-2507" "mistral/pixtral-large-latest" "mistral/mistral-medium-latest" "mistral/mistral-small-latest" "mistral/mistral-medium-2505" "mistral/mistral-large-2411")
 :npm "merge-gateway-ai-sdk-provider")

(provide 'kargu/providers/merge-gateway)

;;; merge-gateway.el ends here
