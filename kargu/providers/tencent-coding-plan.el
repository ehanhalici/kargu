;;; kargu/providers/tencent-coding-plan.el --- Tencent Coding Plan (China) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Tencent Coding Plan (China) (tencent-coding-plan).

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
 :id "tencent-coding-plan"
 :name "Tencent Coding Plan (China)"
 :api "https://api.lkeap.cloud.tencent.com/coding/v3"
 :models-api "https://api.lkeap.cloud.tencent.com/coding/v3/models"
 :env '("TENCENT_CODING_PLAN_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/tencent-coding-plan)

;;; tencent-coding-plan.el ends here
