;;; kargu/providers/fastrouter.el --- FastRouter provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for FastRouter (fastrouter).

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
 :id "fastrouter"
 :name "FastRouter"
 :api "https://go.fastrouter.ai/api/v1"
 :env '("FASTROUTER_API_KEY")
 :models '("wanx/wan-v2-6" "moonshotai/kimi-k2" "moonshotai/kimi-k2.6" "google/imagen-4.0-fast" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash" "google/veo3.1-lite" "google/gemma-4-31b-it" "google/veo3.1" "google/imagen-4.0-ultra" "google/gemini-3-pro-image-preview" "google/gemini-3.1-flash-image-preview" "google/gemini-3.1-pro-preview" "google/veo3.1-fast")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/fastrouter)

;;; fastrouter.el ends here
