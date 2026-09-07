;;; kargu/providers/perplexity-agent.el --- Perplexity Agent provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Perplexity Agent (perplexity-agent).

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
 :id "perplexity-agent"
 :name "Perplexity Agent"
 :api "https://api.perplexity.ai/v1"
 :models-api "https://api.perplexity.ai/v1/models"
 :env '("PERPLEXITY_API_KEY")
 :npm "@ai-sdk/openai")

(provide 'kargu/providers/perplexity-agent)

;;; perplexity-agent.el ends here
