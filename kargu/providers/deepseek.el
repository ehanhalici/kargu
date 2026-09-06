;;; kargu/providers/deepseek.el --- DeepSeek provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for DeepSeek (deepseek).

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
 :id "deepseek"
 :name "DeepSeek"
 :api "https://api.deepseek.com/v1"
 :env '("DEEPSEEK_API_KEY")
 :models '("deepseek-chat" "deepseek-reasoner" "deepseek-v4-flash" "deepseek-v4-pro")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/deepseek)

;;; deepseek.el ends here
