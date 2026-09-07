;;; kargu/providers/neon.el --- Neon provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Neon (neon).

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
 :id "neon"
 :name "Neon"
 :api "${NEON_AI_GATEWAY_BASE_URL}/ai-gateway/mlflow/v1"
 :models-api "${NEON_AI_GATEWAY_BASE_URL}/ai-gateway/mlflow/v1/models"
 :env '("NEON_AI_GATEWAY_BASE_URL" "NEON_AI_GATEWAY_TOKEN")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/neon)

;;; neon.el ends here
