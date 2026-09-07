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
 :models-api "https://${AZURE_COGNITIVE_SERVICES_RESOURCE_NAME}.cognitiveservices.azure.com/models"
 :env '("AZURE_COGNITIVE_SERVICES_RESOURCE_NAME" "AZURE_COGNITIVE_SERVICES_API_KEY")
 :npm "@ai-sdk/azure")

(provide 'kargu/providers/azure-cognitive-services)

;;; azure-cognitive-services.el ends here
