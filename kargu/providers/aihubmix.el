;;; kargu/providers/aihubmix.el --- AIHubMix provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for AIHubMix (aihubmix).

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
 :id "aihubmix"
 :name "AIHubMix"
 :api "https://aihubmix.com/v1"
 :models-api "https://aihubmix.com/v1/models"
 :env '("AIHUBMIX_API_KEY")
 :npm "@aihubmix/ai-sdk-provider")

(provide 'kargu/providers/aihubmix)

;;; aihubmix.el ends here
