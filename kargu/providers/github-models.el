;;; kargu/providers/github-models.el --- GitHub Models provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for GitHub Models (github-models).

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
 :id "github-models"
 :name "GitHub Models"
 :api "https://models.github.ai/inference"
 :env '("GITHUB_TOKEN")
 :models '("ai21-labs/ai21-jamba-1.5-mini" "ai21-labs/ai21-jamba-1.5-large" "core42/jais-30b-chat" "xai/grok-3-mini" "xai/grok-3" "microsoft/phi-3.5-moe-instruct" "microsoft/phi-3-small-128k-instruct" "microsoft/phi-3.5-mini-instruct" "microsoft/phi-3-medium-128k-instruct" "microsoft/phi-3-small-8k-instruct" "microsoft/phi-4-reasoning" "microsoft/mai-ds-r1" "microsoft/phi-4-mini-instruct" "microsoft/phi-4" "microsoft/phi-3.5-vision-instruct")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/github-models)

;;; github-models.el ends here
