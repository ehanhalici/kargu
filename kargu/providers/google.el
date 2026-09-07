;;; kargu/providers/google.el --- Google provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Google (google).

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
 :id "google"
 :name "Google"
 :api "https://generativelanguage.googleapis.com/v1beta/openai"
 :models-api "https://generativelanguage.googleapis.com/v1beta/openai/models"
 :env '("GOOGLE_API_KEY" "GOOGLE_GENERATIVE_AI_API_KEY" "GEMINI_API_KEY")
 :npm "@ai-sdk/google")

(provide 'kargu/providers/google)

;;; google.el ends here
