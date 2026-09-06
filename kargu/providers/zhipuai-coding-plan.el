;;; kargu/providers/zhipuai-coding-plan.el --- Zhipu AI Coding Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Zhipu AI Coding Plan (zhipuai-coding-plan).

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
 :id "zhipuai-coding-plan"
 :name "Zhipu AI Coding Plan"
 :api "https://open.bigmodel.cn/api/coding/paas/v4"
 :env '("ZHIPU_API_KEY")
 :models '("glm-5.1" "glm-5v-turbo" "glm-5-turbo" "glm-4.5-air" "glm-4.6v" "glm-5.2" "glm-4.7")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/zhipuai-coding-plan)

;;; zhipuai-coding-plan.el ends here
