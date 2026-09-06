;;; kargu/providers/perplexity.el --- Perplexity provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Perplexity (perplexity).

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
 :id "perplexity"
 :name "Perplexity"
 :api "https://api.perplexity.ai"
 :env '("PERPLEXITY_API_KEY")
 :models '("sonar" "sonar-pro" "sonar-reasoning" "sonar-reasoning-pro" "sonar-deep-research")
 :npm "@ai-sdk/perplexity")

(provide 'kargu/providers/perplexity)

;;; perplexity.el ends here
