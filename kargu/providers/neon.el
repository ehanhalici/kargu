;;; kargu/providers/neon.el --- Neon provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Neon (neon).

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
 :id "neon"
 :name "Neon"
 :api "${NEON_AI_GATEWAY_BASE_URL}/ai-gateway/mlflow/v1"
 :env '("NEON_AI_GATEWAY_BASE_URL" "NEON_AI_GATEWAY_TOKEN")
 :models '("gemini-3-flash" "claude-sonnet-4" "qwen3-next-80b-a3b-instruct" "llama-4-maverick" "claude-opus-4-5" "gpt-5" "gemma-3-12b" "gpt-5-1-codex-mini" "gpt-5-1" "meta-llama-3-3-70b-instruct" "gemini-3-pro" "gpt-5-2" "gemini-3-1-flash-lite" "claude-sonnet-4-5" "claude-opus-4-7")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/neon)

;;; neon.el ends here
