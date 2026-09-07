;;; kargu/providers/jiekou.el --- Jiekou.AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Jiekou.AI (jiekou).

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
 :id "jiekou"
 :name "Jiekou.AI"
 :api "https://api.jiekou.ai/openai"
 :models-api "https://api.jiekou.ai/openai/models"
 :env '("JIEKOU_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/jiekou)

;;; jiekou.el ends here
