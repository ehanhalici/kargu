;;; kargu/providers/google-vertex.el --- Vertex provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vertex (google-vertex).

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
 :id "google-vertex"
 :name "Vertex"
 :api "https://${GOOGLE_VERTEX_LOCATION}-aiplatform.googleapis.com/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/publishers/google/models"
 :env '("GOOGLE_VERTEX_PROJECT" "GOOGLE_VERTEX_LOCATION" "GOOGLE_APPLICATION_CREDENTIALS")
 :models '("gemini-2.5-pro-tts" "claude-haiku-4-5@20251001" "gemini-3.1-flash-lite" "gemini-3.1-flash-image" "gemini-2.5-pro" "gemini-2.5-flash-tts" "gemini-2.5-flash" "gemini-3.5-flash" "claude-opus-4@20250514" "claude-opus-4-1@20250805" "gemini-embedding-001" "claude-opus-4-5@20251101" "claude-3-5-haiku@20241022" "gemini-3.1-pro-preview-customtools" "gemini-flash-lite-latest")
 :npm "@ai-sdk/google-vertex")

(provide 'kargu/providers/google-vertex)

;;; google-vertex.el ends here
