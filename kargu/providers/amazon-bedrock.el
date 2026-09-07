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
 :models-api "https://bedrock-runtime.us-east-1.amazonaws.com/models"
 :env '("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "AWS_BEARER_TOKEN_BEDROCK")
 :npm "@ai-sdk/amazon-bedrock")

(provide 'kargu/providers/amazon-bedrock)

;;; amazon-bedrock.el ends here
