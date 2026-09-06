;;; kargu/providers/anthropic.el --- Anthropic provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Anthropic (anthropic).

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
 :id "anthropic"
 :name "Anthropic"
 :api "https://api.anthropic.com/v1"
 :env '("ANTHROPIC_API_KEY")
 :models '("claude-3-5-sonnet-latest" "claude-3-5-haiku-latest" "claude-3-opus-latest" "claude-opus-4-5" "claude-haiku-4-5-20251001" "claude-opus-4-1-20250805" "claude-sonnet-4-5" "claude-opus-4-7" "claude-sonnet-5" "claude-opus-4-5-20251101" "claude-opus-4-8" "claude-opus-4-1" "claude-fable-5" "claude-haiku-4-5" "claude-opus-4-6")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/anthropic)

;;; anthropic.el ends here
