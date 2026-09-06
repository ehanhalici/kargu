;;; kargu/providers/requesty.el --- Requesty provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Requesty (requesty).

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
 :id "requesty"
 :name "Requesty"
 :api "https://router.requesty.ai/v1"
 :env '("REQUESTY_API_KEY")
 :models '("xai/grok-4" "xai/grok-4-fast" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "openai/gpt-5.2-chat" "openai/gpt-5.2-pro" "openai/gpt-5" "openai/gpt-5-chat" "openai/gpt-5-pro" "openai/o4-mini" "openai/gpt-5.1-chat" "openai/gpt-5.1-codex" "openai/gpt-5.1-codex-max")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/requesty)

;;; requesty.el ends here
