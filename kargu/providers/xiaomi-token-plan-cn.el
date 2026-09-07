;;; kargu/providers/xiaomi-token-plan-cn.el --- Xiaomi Token Plan (China) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Xiaomi Token Plan (China) (xiaomi-token-plan-cn).

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
 :id "xiaomi-token-plan-cn"
 :name "Xiaomi Token Plan (China)"
 :api "https://token-plan-cn.xiaomimimo.com/v1"
 :models-api "https://token-plan-cn.xiaomimimo.com/v1/models"
 :env '("XIAOMI_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/xiaomi-token-plan-cn)

;;; xiaomi-token-plan-cn.el ends here
