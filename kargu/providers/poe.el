;;; kargu/providers/poe.el --- Poe provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Poe (poe).

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
 :id "poe"
 :name "Poe"
 :api "https://api.poe.com/v1"
 :env '("POE_API_KEY")
 :models '("trytako/tako" "xai/grok-code-fast-1" "xai/grok-4.1-fast-reasoning" "xai/grok-3-mini" "xai/grok-4.1-fast-non-reasoning" "xai/grok-3" "xai/grok-4-fast-reasoning" "xai/grok-4" "xai/grok-4-fast-non-reasoning" "xai/grok-4.20-multi-agent" "topazlabs-co/topazlabs" "fireworks-ai/kimi-k2.5-fw" "google/veo-3.1-fast" "google/imagen-3" "google/nano-banana-pro")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/poe)

;;; poe.el ends here
