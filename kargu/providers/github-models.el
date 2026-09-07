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
 :models-api "https://models.github.ai/inference/models"
 :env '("GITHUB_TOKEN")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/github-models)

;;; github-models.el ends here
