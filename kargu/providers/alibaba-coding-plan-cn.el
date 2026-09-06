;;; kargu/providers/alibaba-coding-plan-cn.el --- Alibaba Coding Plan (China) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Alibaba Coding Plan (China) (alibaba-coding-plan-cn).

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
 :id "alibaba-coding-plan-cn"
 :name "Alibaba Coding Plan (China)"
 :api "https://coding.dashscope.aliyuncs.com/v1"
 :env '("ALIBABA_CODING_PLAN_API_KEY")
 :models '("qwen3-coder-plus" "glm-4.7" "qwen3.7-plus" "qwen3.7-max" "qwen3.6-flash" "qwen3-max-2026-01-23" "qwen3.5-plus" "kimi-k2.5" "MiniMax-M2.5" "qwen3-coder-next" "glm-5" "qwen3.6-plus")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-coding-plan-cn)

;;; alibaba-coding-plan-cn.el ends here
