;;; kargu/providers/openai.el --- OpenAI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenAI (openai).

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
 :id "openai"
 :name "OpenAI"
 :api "https://api.openai.com/v1"
 :env '("OPENAI_API_KEY")
 :models '("gpt-4o" "gpt-4o-mini" "o1" "o3-mini" "gpt-4.5-preview" "o3" "text-embedding-3-large" "gpt-5.2-pro" "gpt-5.6" "gpt-5" "gpt-3.5-turbo" "gpt-5-pro" "gpt-4" "o4-mini" "o3-pro")
 :npm "@ai-sdk/openai")

(provide 'kargu/providers/openai)

;;; openai.el ends here
