;;; kargu/providers/cerebras.el --- Cerebras provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Cerebras (cerebras).

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
 :id "cerebras"
 :name "Cerebras"
 :api "https://api.cerebras.ai/v1"
 :models-api "https://api.cerebras.ai/v1/models"
 :env '("CEREBRAS_API_KEY")
 :npm "@ai-sdk/cerebras")

(provide 'kargu/providers/cerebras)

;;; cerebras.el ends here
