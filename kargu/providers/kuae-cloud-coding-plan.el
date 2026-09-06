;;; kargu/providers/kuae-cloud-coding-plan.el --- KUAE Cloud Coding Plan provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for KUAE Cloud Coding Plan (kuae-cloud-coding-plan).

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
 :id "kuae-cloud-coding-plan"
 :name "KUAE Cloud Coding Plan"
 :api "https://coding-plan-endpoint.kuaecloud.net/v1"
 :env '("KUAE_API_KEY")
 :models '("GLM-4.7")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/kuae-cloud-coding-plan)

;;; kuae-cloud-coding-plan.el ends here
