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
 :env '("COHERE_API_KEY")
 :models '("command-r-plus" "command-r" "c4ai-aya-expanse-32b" "command-a-03-2025" "c4ai-aya-vision-32b" "command-r7b-arabic-02-2025" "c4ai-aya-vision-8b" "command-r-08-2024" "command-r7b-12-2024" "command-a-vision-07-2025" "command-a-plus-05-2026" "command-a-translate-08-2025" "command-r-plus-08-2024" "command-a-reasoning-08-2025" "north-mini-code-1-0")
 :npm "@ai-sdk/cohere")

(provide 'kargu/providers/cohere)

;;; cohere.el ends here
