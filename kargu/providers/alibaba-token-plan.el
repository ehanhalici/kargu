;;; kargu/providers/alibaba-token-plan.el --- Alibaba Token Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Alibaba Token Plan (alibaba-token-plan).

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
 :id "alibaba-token-plan"
 :name "Alibaba Token Plan"
 :api "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
 :env '("ALIBABA_TOKEN_PLAN_API_KEY")
 :models '("deepseek-v4-flash" "qwen3.7-plus" "qwen3.7-max" "kimi-k2.7-code" "glm-5.1" "deepseek-v4-pro" "wan2.7-image-pro" "glm-5.2" "qwen3.6-flash" "kimi-k2.5" "qwen-image-2.0" "MiniMax-M2.5" "kimi-k2.6" "qwen-image-2.0-pro" "wan2.7-image")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-token-plan)

;;; alibaba-token-plan.el ends here
