;;; kargu/providers/databricks.el --- Databricks provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Databricks (databricks).

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
 :id "databricks"
 :name "Databricks"
 :api "https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1"
 :env '("DATABRICKS_HOST" "DATABRICKS_TOKEN")
 :models '("databricks-claude-opus-4-7" "databricks-gpt-5-4" "databricks-gemini-3-flash" "databricks-claude-opus-4-5" "databricks-gpt-5-nano" "databricks-gpt-5-mini" "databricks-gpt-5" "databricks-gemini-2-5-pro" "databricks-gemini-3-1-pro" "databricks-gemini-2-5-flash" "databricks-claude-sonnet-4" "databricks-glm-5-2" "databricks-claude-haiku-4-5" "databricks-gpt-5-4-nano" "databricks-claude-opus-4-6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/databricks)

;;; databricks.el ends here
