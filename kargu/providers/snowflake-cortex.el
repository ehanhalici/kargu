;;; kargu/providers/snowflake-cortex.el --- Snowflake Cortex provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Snowflake Cortex (snowflake-cortex).

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
 :id "snowflake-cortex"
 :name "Snowflake Cortex"
 :api "https://${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com/api/v2/cortex/v1"
 :models-api "https://${SNOWFLAKE_ACCOUNT}.snowflakecomputing.com/api/v2/cortex/v1/models"
 :env '("SNOWFLAKE_ACCOUNT" "SNOWFLAKE_CORTEX_PAT")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/snowflake-cortex)

;;; snowflake-cortex.el ends here
