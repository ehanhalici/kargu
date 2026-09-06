;;; kargu/providers/orcarouter.el --- OrcaRouter provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OrcaRouter (orcarouter).

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
 :id "orcarouter"
 :name "OrcaRouter"
 :api "https://api.orcarouter.ai/v1"
 :env '("ORCAROUTER_API_KEY")
 :models '("google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemma-4-31b-it" "google/gemini-3.1-pro-preview-customtools" "google/gemini-flash-lite-latest" "google/gemini-2.5-flash-lite" "google/gemini-3.1-pro-preview" "google/gemma-4-26b-a4b-it" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "google/gemini-flash-latest" "google/gemini-3.1-flash-lite-preview" "z-ai/glm-4.7" "z-ai/glm-4.5" "z-ai/glm-5.1")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/orcarouter)

;;; orcarouter.el ends here
