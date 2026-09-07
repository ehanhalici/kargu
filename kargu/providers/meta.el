;;; kargu/providers/meta.el --- Meta provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Meta (meta).

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
 :id "meta"
 :name "Meta"
 :api "https://api.meta.ai/v1"
 :models-api "https://api.meta.ai/v1/models"
 :env '("META_MODEL_API_KEY")
 :npm "@ai-sdk/openai")

(provide 'kargu/providers/meta)

;;; meta.el ends here
