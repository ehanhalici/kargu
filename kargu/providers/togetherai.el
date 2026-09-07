;;; kargu/providers/togetherai.el --- Together AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Together AI (togetherai).

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
 :id "togetherai"
 :name "Together AI"
 :api "https://api.together.xyz/v1"
 :models-api "https://api.together.xyz/v1/models"
 :env '("TOGETHER_API_KEY")
 :npm "@ai-sdk/togetherai")

(provide 'kargu/providers/togetherai)

;;; togetherai.el ends here
