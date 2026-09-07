;;; kargu/providers/mistral.el --- Mistral provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Mistral (mistral).

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
 :id "mistral"
 :name "Mistral"
 :api "https://api.mistral.ai/v1"
 :models-api "https://api.mistral.ai/v1/models"
 :env '("MISTRAL_API_KEY")
 :npm "@ai-sdk/mistral")

(provide 'kargu/providers/mistral)

;;; mistral.el ends here
