;;; kargu/providers/xiaomi.el --- Xiaomi provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Xiaomi (xiaomi).

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
 :id "xiaomi"
 :name "Xiaomi"
 :api "https://api.xiaomimimo.com/v1"
 :env '("XIAOMI_API_KEY")
 :models '("mimo-v2.5-pro-ultraspeed" "mimo-v2.5" "mimo-v2-omni" "mimo-v2-flash" "mimo-v2-pro" "mimo-v2.5-pro")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/xiaomi)

;;; xiaomi.el ends here
