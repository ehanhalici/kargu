;;; kargu/providers/xai.el --- xAI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for xAI (xai).

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
 :id "xai"
 :name "xAI"
 :api "https://api.x.ai/v1"
 :env '("XAI_API_KEY")
 :models '("grok-2-latest" "grok-2-vision-latest" "grok-beta" "grok-4.20-multi-agent-0309" "grok-4.20-0309-non-reasoning" "grok-4.3" "grok-imagine-image-quality" "grok-imagine-video" "grok-4.5" "grok-4.20-0309-reasoning" "grok-imagine-image" "grok-build-0.1")
 :npm "@ai-sdk/xai")

(provide 'kargu/providers/xai)

;;; xai.el ends here
