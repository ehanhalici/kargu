;;; kargu/providers/merge-gateway.el --- Merge Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Merge Gateway (merge-gateway).

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
 :id "merge-gateway"
 :name "Merge Gateway"
 :api "https://ai.mergegateway.com/v1"
 :models-api "https://ai.mergegateway.com/v1/models"
 :env '("MERGE_GATEWAY_API_KEY")
 :npm "merge-gateway-ai-sdk-provider")

(provide 'kargu/providers/merge-gateway)

;;; merge-gateway.el ends here
