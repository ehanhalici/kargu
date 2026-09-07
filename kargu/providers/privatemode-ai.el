;;; kargu/providers/privatemode-ai.el --- Privatemode AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Privatemode AI (privatemode-ai).

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
 :id "privatemode-ai"
 :name "Privatemode AI"
 :api "http://localhost:8080/v1"
 :models-api "http://localhost:8080/v1/models"
 :env '("PRIVATEMODE_API_KEY" "PRIVATEMODE_ENDPOINT")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/privatemode-ai)

;;; privatemode-ai.el ends here
