;;; kargu/providers/alibaba-coding-plan.el --- Alibaba Coding Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Alibaba Coding Plan (alibaba-coding-plan).

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
 :id "alibaba-coding-plan"
 :name "Alibaba Coding Plan"
 :api "https://coding-intl.dashscope.aliyuncs.com/v1"
 :models-api "https://coding-intl.dashscope.aliyuncs.com/v1/models"
 :env '("ALIBABA_CODING_PLAN_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-coding-plan)

;;; alibaba-coding-plan.el ends here
