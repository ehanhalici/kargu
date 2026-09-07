;;; kargu/providers/claudinio.el --- Claudinio provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Claudinio (claudinio).

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
 :id "claudinio"
 :name "Claudinio"
 :api "https://api.claudin.io/v1"
 :models-api "https://api.claudin.io/v1/models"
 :env '("CLAUDINIO_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/claudinio)

;;; claudinio.el ends here
