;;; kargu/providers/privatemode-ai.el --- Privatemode AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Privatemode AI (privatemode-ai).

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
 :id "privatemode-ai"
 :name "Privatemode AI"
 :api "http://localhost:8080/v1"
 :env '("PRIVATEMODE_API_KEY" "PRIVATEMODE_ENDPOINT")
 :models '("qwen3-embedding-4b" "gemma-3-27b" "gpt-oss-120b" "whisper-large-v3" "qwen3-coder-30b-a3b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/privatemode-ai)

;;; privatemode-ai.el ends here
