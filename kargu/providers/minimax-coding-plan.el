;;; kargu/providers/minimax-coding-plan.el --- MiniMax Token Plan (minimax.io) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for MiniMax Token Plan (minimax.io) (minimax-coding-plan).

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
 :id "minimax-coding-plan"
 :name "MiniMax Token Plan (minimax.io)"
 :api "https://api.minimax.io/anthropic/v1"
 :models-api "https://api.minimax.io/anthropic/v1/models"
 :env '("MINIMAX_API_KEY")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/minimax-coding-plan)

;;; minimax-coding-plan.el ends here
