;;; kargu/providers/venice.el --- Venice AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Venice AI (venice).

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
 :id "venice"
 :name "Venice AI"
 :api "https://api.venice.ai/api/v1"
 :models-api "https://api.venice.ai/api/v1/models"
 :env '("VENICE_API_KEY")
 :npm "venice-ai-sdk-provider")

(provide 'kargu/providers/venice)

;;; venice.el ends here
