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
 :env '("MODEL_ORACLE_API_KEY")
 :models '("gpt-5" "claude-haiku-4.5" "o4-mini" "deepseek-v4-pro" "claude-sonnet-5" "gpt-5.4-nano" "glm-5.2" "claude-opus-4.8" "claude-fable-5" "gpt-5.4" "gpt-5.4-mini" "gpt-4.1" "gpt-4.1-mini" "auto" "gpt-5.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/model-oracle-ai)

;;; model-oracle-ai.el ends here
