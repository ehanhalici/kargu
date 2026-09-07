;;; kargu/providers/clarifai.el --- Clarifai provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Clarifai (clarifai).

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
 :id "clarifai"
 :name "Clarifai"
 :api "https://api.clarifai.com/v2/ext/openai/v1"
 :models-api "https://api.clarifai.com/v2/ext/openai/v1/models"
 :env '("CLARIFAI_PAT")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/clarifai)

;;; clarifai.el ends here
