;;; kargu/providers/umans-ai-coding-plan.el --- Umans AI Coding Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Umans AI Coding Plan (umans-ai-coding-plan).

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
 :id "umans-ai-coding-plan"
 :name "Umans AI Coding Plan"
 :api "https://api.code.umans.ai/v1"
 :models-api "https://api.code.umans.ai/v1/models"
 :env '("UMANS_AI_CODING_PLAN_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/umans-ai-coding-plan)

;;; umans-ai-coding-plan.el ends here
