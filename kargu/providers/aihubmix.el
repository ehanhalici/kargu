;;; kargu/providers/aihubmix.el --- AIHubMix provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for AIHubMix (aihubmix).

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
 :id "aihubmix"
 :name "AIHubMix"
 :api "https://aihubmix.com/v1"
 :env '("AIHUBMIX_API_KEY")
 :models '("coding-minimax-m2.7" "alicloud-glm-5.1" "claude-sonnet-4-6-think" "gemini-3.1-flash-lite" "alicloud-deepseek-v4-flash" "xiaomi-mimo-v2.5-pro" "doubao-seed-2-0-code-preview" "coding-xiaomi-mimo-v2.5-pro" "doubao-seed-2-0-pro" "deep-deepseek-v4-flash" "qwen3.7-plus" "gemini-2.5-pro" "grok-4.3" "qwen3.7-max" "gemini-2.5-flash")
 :npm "@aihubmix/ai-sdk-provider")

(provide 'kargu/providers/aihubmix)

;;; aihubmix.el ends here
