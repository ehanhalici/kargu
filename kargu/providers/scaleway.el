;;; kargu/providers/scaleway.el --- Scaleway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Scaleway (scaleway).

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
 :id "scaleway"
 :name "Scaleway"
 :api "https://api.scaleway.ai/v1"
 :models-api "https://api.scaleway.ai/v1/models"
 :env '("SCALEWAY_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/scaleway)

;;; scaleway.el ends here
