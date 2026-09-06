;;; kargu/providers/scaleway.el --- Scaleway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Scaleway (scaleway).

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
 :id "scaleway"
 :name "Scaleway"
 :api "https://api.scaleway.ai/v1"
 :env '("SCALEWAY_API_KEY")
 :models '("qwen3-235b-a22b-instruct-2507" "qwen3-coder-30b-a3b-instruct" "qwen3-embedding-8b" "bge-multilingual-gemma2" "qwen3.6-35b-a3b" "llama-3.3-70b-instruct" "glm-5.2" "pixtral-12b-2409" "mistral-small-3.2-24b-instruct-2506" "gpt-oss-120b" "gemma-4-26b-a4b-it" "mistral-medium-3.5-128b" "qwen3.5-397b-a17b" "whisper-large-v3" "gemma-3-27b-it")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/scaleway)

;;; scaleway.el ends here
