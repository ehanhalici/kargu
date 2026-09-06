;;; kargu/providers/subconscious.el --- Subconscious provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Subconscious (subconscious).

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
 :id "subconscious"
 :name "Subconscious"
 :api "https://api.subconscious.dev/v1"
 :env '("SUBCONSCIOUS_API_KEY")
 :models '("subconscious/glm-5.2" "subconscious/tim-qwen3.6-27b")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/subconscious)

;;; subconscious.el ends here
