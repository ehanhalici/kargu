;;; kargu/providers/tencent-token-plan.el --- Tencent Token Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Tencent Token Plan (tencent-token-plan).

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
 :id "tencent-token-plan"
 :name "Tencent Token Plan"
 :api "https://api.lkeap.cloud.tencent.com/plan/v3"
 :models-api "https://api.lkeap.cloud.tencent.com/plan/v3/models"
 :env '("TENCENT_TOKEN_PLAN_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/tencent-token-plan)

;;; tencent-token-plan.el ends here
