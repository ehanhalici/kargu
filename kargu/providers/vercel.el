;;; kargu/providers/vercel.el --- Vercel AI Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vercel AI Gateway (vercel).

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
 :id "vercel"
 :name "Vercel AI Gateway"
 :api "https://api.vercel.com/v1/ai"
 :env '("AI_GATEWAY_API_KEY")
 :models '("xai/grok-imagine-video-1.5" "xai/grok-4.1-fast-reasoning" "xai/grok-4.20-non-reasoning-beta" "xai/grok-4.3" "xai/grok-tts" "xai/grok-4.1-fast-non-reasoning" "xai/grok-voice-think-fast-1.0" "xai/grok-imagine-video" "xai/grok-4.20-multi-agent-beta" "xai/grok-stt" "xai/grok-4.5" "xai/grok-4.20-reasoning" "xai/grok-4.20-reasoning-beta" "xai/grok-imagine-video-1.5-preview" "xai/grok-4.20-non-reasoning")
 :npm "@ai-sdk/gateway")

(provide 'kargu/providers/vercel)

;;; vercel.el ends here
