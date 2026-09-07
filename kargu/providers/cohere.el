;;; kargu/providers/cohere.el --- Cohere provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Cohere (cohere).

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
 :id "cohere"
 :name "Cohere"
 :api "https://api.cohere.com/v2"
 :models-api "https://api.cohere.com/v2/models"
 :env '("COHERE_API_KEY")
 :npm "@ai-sdk/cohere")

(provide 'kargu/providers/cohere)

;;; cohere.el ends here
