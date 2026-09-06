;;; kargu/providers/morph.el --- Morph provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Morph (morph).

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
 :id "morph"
 :name "Morph"
 :api "https://api.morphllm.com/v1"
 :env '("MORPH_API_KEY")
 :models '("morph-v3-fast" "morph-v3-large" "auto")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/morph)

;;; morph.el ends here
