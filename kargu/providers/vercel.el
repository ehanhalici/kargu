;;; kargu/providers/vercel.el --- Vercel AI Gateway provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vercel AI Gateway (vercel).

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
 :id "vercel"
 :name "Vercel AI Gateway"
 :api "https://api.vercel.com/v1/ai"
 :models-api "https://api.vercel.com/v1/ai/models"
 :env '("AI_GATEWAY_API_KEY")
 :npm "@ai-sdk/gateway")

(provide 'kargu/providers/vercel)

;;; vercel.el ends here
