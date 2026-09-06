;;; kargu/providers/lilac.el --- Lilac provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Lilac (lilac).

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
 :id "lilac"
 :name "Lilac"
 :api "https://api.getlilac.com/v1"
 :env '("LILAC_API_KEY")
 :models '("moonshotai/kimi-k2.6" "minimaxai/minimax-m3" "google/gemma-4-31b-it" "zai-org/glm-5.2")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/lilac)

;;; lilac.el ends here
