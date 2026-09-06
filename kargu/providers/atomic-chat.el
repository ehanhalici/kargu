;;; kargu/providers/atomic-chat.el --- Atomic Chat provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Atomic Chat (atomic-chat).

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
 :id "atomic-chat"
 :name "Atomic Chat"
 :api "http://127.0.0.1:1337/v1"
 :env '("ATOMIC_CHAT_API_KEY")
 :models '("gemma-4-E4B-it-IQ4_XS" "Meta-Llama-3_1-8B-Instruct-GGUF" "Qwen3_5-9B-MLX-4bit" "gemma-4-E4B-it-MLX-4bit" "Qwen3_5-9B-Q4_K_M")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/atomic-chat)

;;; atomic-chat.el ends here
