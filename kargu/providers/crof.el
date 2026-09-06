;;; kargu/providers/crof.el --- CrofAI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for CrofAI (crof).

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
 :id "crof"
 :name "CrofAI"
 :api "https://crof.ai/v1"
 :env '("CROF_API_KEY")
 :models '("deepseek-v4-flash" "minimax-m2.5" "greg-2-ultra" "glm-4.7" "deepseek-v4-pro-lightning" "greg-rp" "gemma-4-31b-it" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "glm-5.2" "greg-2-super" "kimi-k2.5-lightning" "kimi-k2.5" "kimi-k2.6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/crof)

;;; crof.el ends here
