;;; kargu/providers/github-copilot.el --- GitHub Copilot provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for GitHub Copilot (github-copilot).

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
 :id "github-copilot"
 :name "GitHub Copilot"
 :api "https://api.githubcopilot.com"
 :env '("GITHUB_TOKEN")
 :models '("claude-sonnet-4.5" "claude-sonnet-4" "gemini-2.5-pro" "claude-haiku-4.5" "gemini-3.5-flash" "kimi-k2.7-code" "claude-sonnet-5" "gpt-5.4-nano" "claude-opus-4.7" "mai-code-1-flash-picker" "gpt-5.2" "gpt-5.3-codex" "gpt-5.6-luna" "gpt-5.6-terra" "claude-opus-4.8")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/github-copilot)

;;; github-copilot.el ends here
