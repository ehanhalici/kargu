;;; kargu/providers/umans-ai.el --- Umans AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Umans AI (umans-ai).

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
 :id "umans-ai"
 :name "Umans AI"
 :api "https://api.code.umans.ai/v1"
 :env '("UMANS_AI_API_KEY")
 :models '("umans-kimi-k2.7" "umans-glm-5.1" "umans-coder" "umans-flash" "umans-glm-5.2")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/umans-ai)

;;; umans-ai.el ends here
