;;; kargu/providers/azure.el --- Azure provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Azure (azure).

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
 :id "azure"
 :name "Azure"
 :api "https://${AZURE_RESOURCE_NAME}.openai.azure.com/openai/deployments"
 :models-api "https://${AZURE_RESOURCE_NAME}.openai.azure.com/openai/deployments/models"
 :env '("AZURE_RESOURCE_NAME" "AZURE_API_KEY")
 :npm "@ai-sdk/azure")

(provide 'kargu/providers/azure)

;;; azure.el ends here
