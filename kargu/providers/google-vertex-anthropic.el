;;; kargu/providers/google-vertex-anthropic.el --- Vertex (Anthropic) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vertex (Anthropic) (google-vertex-anthropic).

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
 :id "google-vertex-anthropic"
 :name "Vertex (Anthropic)"
 :api "https://aiplatform.${GOOGLE_VERTEX_LOCATION}.rep.googleapis.com/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/publishers/anthropic/models"
 :models-api "https://aiplatform.${GOOGLE_VERTEX_LOCATION}.rep.googleapis.com/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/publishers/anthropic/models"
 :env '("GOOGLE_VERTEX_PROJECT" "GOOGLE_VERTEX_LOCATION" "GOOGLE_APPLICATION_CREDENTIALS")
 :npm "@ai-sdk/google-vertex/anthropic")

(provide 'kargu/providers/google-vertex-anthropic)

;;; google-vertex-anthropic.el ends here
