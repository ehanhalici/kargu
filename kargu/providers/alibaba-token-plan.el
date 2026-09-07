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
 :models-api "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/models"
 :env '("ALIBABA_TOKEN_PLAN_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-token-plan)

;;; alibaba-token-plan.el ends here
