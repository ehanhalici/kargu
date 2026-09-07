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
 :models-api "https://${DATABRICKS_HOST}/ai-gateway/mlflow/v1/models"
 :env '("DATABRICKS_HOST" "DATABRICKS_TOKEN")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/databricks)

;;; databricks.el ends here
