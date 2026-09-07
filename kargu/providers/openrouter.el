;;; kargu/providers/openrouter.el --- OpenRouter provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenRouter (openrouter).

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
 :id "openrouter"
 :name "OpenRouter"
 :api "https://openrouter.ai/api/v1"
 :models-api "https://openrouter.ai/api/v1/models"
 :usage-api "https://openrouter.ai/api/v1/auth/key"
 :env '("OPENROUTER_API_KEY")
 :npm "@openrouter/ai-sdk-provider")

(provide 'kargu/providers/openrouter)

;;; openrouter.el ends here
