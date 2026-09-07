;;; kargu/providers/model-oracle-ai.el --- Model Oracle AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Model Oracle AI (model-oracle-ai).

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
 :id "model-oracle-ai"
 :name "Model Oracle AI"
 :api "https://api.modeloracle.com/api/v1"
 :models-api "https://api.modeloracle.com/api/v1/models"
 :env '("MODEL_ORACLE_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/model-oracle-ai)

;;; model-oracle-ai.el ends here
