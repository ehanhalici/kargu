;;; kargu/providers/pioneer.el --- Pioneer provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Pioneer (pioneer).

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
 :id "pioneer"
 :name "Pioneer"
 :api "https://api.pioneer.ai/v1"
 :env '("PIONEER_API_KEY")
 :models '("gemini-3-flash" "qwen3.7-plus" "claude-opus-4-5" "qwen3.7-max" "gpt-4o" "gemini-3.5-flash" "claude-sonnet-4-5" "claude-opus-4-7" "gpt-5.4-nano" "qwen3.6-flash" "claude-opus-4-8" "mistral-medium-3.5" "gpt-5.3-codex" "claude-opus-4-1" "gpt-4.1-nano")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/pioneer)

;;; pioneer.el ends here
