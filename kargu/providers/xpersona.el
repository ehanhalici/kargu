;;; kargu/providers/xpersona.el --- Xpersona provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Xpersona (xpersona).

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
 :id "xpersona"
 :name "Xpersona"
 :api "https://www.xpersona.co/v1"
 :env '("XPERSONA_API_KEY")
 :models '("xpersona-gpt-5.5" "xpersona-frieren-coder" "claude-fable-5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/xpersona)

;;; xpersona.el ends here
