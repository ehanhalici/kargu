;;; kargu/providers/empiriolabs.el --- EmpirioLabs AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for EmpirioLabs AI (empiriolabs).

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
 :id "empiriolabs"
 :name "EmpirioLabs AI"
 :api "https://api.empiriolabs.ai/v1"
 :env '("EMPIRIOLABS_API_KEY")
 :models '("qwen3-5-plus" "deepseek-v4-flash" "kimi-k2-6" "qwen3-5-27b" "step-3-7-flash" "qwen3-5-397b-a17b" "qwen3-5-35b-a3b" "qwen3-max" "glm-5-1" "qwen3-7-plus" "kimi-k2-7-code" "deepseek-v4-pro" "glm-4-5-flash" "qwen3-6-flash" "minimax-m2-7-highspeed")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/empiriolabs)

;;; empiriolabs.el ends here
