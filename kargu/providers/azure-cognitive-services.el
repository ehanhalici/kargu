;;; kargu/providers/azure-cognitive-services.el --- Azure Cognitive Services provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Azure Cognitive Services (azure-cognitive-services).

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
 :id "azure-cognitive-services"
 :name "Azure Cognitive Services"
 :api "https://${AZURE_COGNITIVE_SERVICES_RESOURCE_NAME}.cognitiveservices.azure.com"
 :env '("AZURE_COGNITIVE_SERVICES_RESOURCE_NAME" "AZURE_COGNITIVE_SERVICES_API_KEY")
 :models '("claude-opus-4-5" "claude-sonnet-4-5" "gpt-5.4-nano" "claude-opus-4-8" "claude-opus-4-1" "kimi-k2.5" "claude-haiku-4-5" "gpt-5.4" "gpt-5.4-mini" "kimi-k2.6" "claude-opus-4-6" "gpt-5.4-pro" "gpt-5.5" "gpt-5.1" "meta-llama-3-70b-instruct")
 :npm "@ai-sdk/azure")

(provide 'kargu/providers/azure-cognitive-services)

;;; azure-cognitive-services.el ends here
