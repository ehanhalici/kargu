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
 :env '("SNOWFLAKE_ACCOUNT" "SNOWFLAKE_CORTEX_PAT")
 :models '("openai-gpt-5.1" "snowflake-llama3.3-70b" "openai-gpt-5.2" "claude-sonnet-4-5" "claude-opus-4-7" "deepseek-r1" "claude-opus-4-8" "openai-gpt-5" "openai-gpt-5.5" "claude-fable-5" "openai-gpt-5-nano" "claude-haiku-4-5" "mistral-large2" "openai-gpt-4.1" "claude-sonnet-4-6")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/snowflake-cortex)

;;; snowflake-cortex.el ends here
