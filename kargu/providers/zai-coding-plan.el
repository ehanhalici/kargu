;;; kargu/providers/zai-coding-plan.el --- Z.AI Coding Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Z.AI Coding Plan (zai-coding-plan).

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
 :id "zai-coding-plan"
 :name "Z.AI Coding Plan"
 :api "https://api.z.ai/api/coding/paas/v4"
 :models-api "https://api.z.ai/api/coding/paas/v4/models"
 :env '("ZHIPU_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/zai-coding-plan)

;;; zai-coding-plan.el ends here
