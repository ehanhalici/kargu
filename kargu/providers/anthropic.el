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
 :models-api "https://api.anthropic.com/v1/models"
 :extra-headers '(("anthropic-version" . "2023-06-01"))
 :env '("ANTHROPIC_API_KEY")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/anthropic)

;;; anthropic.el ends here
