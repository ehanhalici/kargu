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
 :models-api "https://api.githubcopilot.com/models"
 :env '("GITHUB_TOKEN")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/github-copilot)

;;; github-copilot.el ends here
