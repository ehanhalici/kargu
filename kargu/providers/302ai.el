;;; kargu/providers/302ai.el --- 302.AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for 302.AI (302ai).

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
 :id "302ai"
 :name "302.AI"
 :api "https://api.302.ai/v1"
 :models-api "https://api.302.ai/v1/models"
 :env '("302AI_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/302ai)

;;; 302ai.el ends here
