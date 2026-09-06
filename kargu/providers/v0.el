;;; kargu/providers/v0.el --- v0 provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for v0 (v0).

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
 :id "v0"
 :name "v0"
 :api "https://api.v0.dev/v1"
 :env '("V0_API_KEY")
 :models '("v0-1.0-md" "v0-1.5-lg" "v0-1.5-md")
 :npm "@ai-sdk/vercel")

(provide 'kargu/providers/v0)

;;; v0.el ends here
