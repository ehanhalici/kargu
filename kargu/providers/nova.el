;;; kargu/providers/nova.el --- Nova provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Nova (nova).

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
 :id "nova"
 :name "Nova"
 :api "https://api.nova.amazon.com/v1"
 :env '("NOVA_API_KEY")
 :models '("nova-2-pro-v1" "nova-2-lite-v1")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nova)

;;; nova.el ends here
