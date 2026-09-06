;;; kargu/providers/amazon-bedrock.el --- Amazon Bedrock provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Amazon Bedrock (amazon-bedrock).

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
 :id "amazon-bedrock"
 :name "Amazon Bedrock"
 :api "https://bedrock-runtime.us-east-1.amazonaws.com"
 :env '("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "AWS_BEARER_TOKEN_BEDROCK")
 :models '("global.anthropic.claude-haiku-4-5-20251001-v1:0" "global.anthropic.claude-sonnet-4-5-20250929-v1:0" "jp.anthropic.claude-haiku-4-5-20251001-v1:0" "us.meta.llama4-scout-17b-instruct-v1:0" "minimax.minimax-m2" "anthropic.claude-opus-4-7" "eu.anthropic.claude-sonnet-4-6" "mistral.voxtral-small-24b-2507" "mistral.ministral-3-3b-instruct" "openai.gpt-oss-20b" "anthropic.claude-opus-4-6-v1" "openai.gpt-oss-safeguard-20b" "anthropic.claude-opus-4-5-20251101-v1:0" "global.anthropic.claude-fable-5" "openai.gpt-oss-120b-1:0")
 :npm "@ai-sdk/amazon-bedrock")

(provide 'kargu/providers/amazon-bedrock)

;;; amazon-bedrock.el ends here
