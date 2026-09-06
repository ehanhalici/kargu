;;; kargu/providers/moonshotai.el --- Moonshot AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Moonshot AI (moonshotai).

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
 :id "moonshotai"
 :name "Moonshot AI"
 :api "https://api.moonshot.ai/v1"
 :env '("MOONSHOT_API_KEY")
 :models '("kimi-k2-0905-preview" "kimi-k2-thinking-turbo" "kimi-k2.7-code" "kimi-k2-thinking" "kimi-k2-0711-preview" "kimi-k2-turbo-preview" "kimi-k2.5" "kimi-k2.6" "kimi-k2.7-code-highspeed")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/moonshotai)

;;; moonshotai.el ends here
