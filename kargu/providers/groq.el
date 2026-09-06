;;; kargu/providers/groq.el --- Groq provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Groq (groq).

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
 :id "groq"
 :name "Groq"
 :api "https://api.groq.com/openai/v1"
 :env '("GROQ_API_KEY")
 :models '("llama-3.3-70b-versatile" "llama-3.1-8b-instant" "mixtral-8x7b-32768" "whisper-large-v3-turbo" "whisper-large-v3" "meta-llama/llama-prompt-guard-2-86m" "meta-llama/llama-prompt-guard-2-22m" "meta-llama/llama-4-scout-17b-16e-instruct" "openai/gpt-oss-safeguard-20b" "openai/gpt-oss-120b" "openai/gpt-oss-20b" "canopylabs/orpheus-v1-english" "canopylabs/orpheus-arabic-saudi" "groq/compound" "groq/compound-mini")
 :npm "@ai-sdk/groq")

(provide 'kargu/providers/groq)

;;; groq.el ends here
