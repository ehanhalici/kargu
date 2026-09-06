;;; kargu/providers/minimax.el --- MiniMax (minimax.io) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for MiniMax (minimax.io) (minimax).

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
 :id "minimax"
 :name "MiniMax (minimax.io)"
 :api "https://api.minimax.io/anthropic/v1"
 :env '("MINIMAX_API_KEY")
 :models '("MiniMax-M2.1" "MiniMax-M2.5-highspeed" "MiniMax-M2.7-highspeed" "MiniMax-M2" "MiniMax-M2.5" "MiniMax-M3" "MiniMax-M2.7")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/minimax)

;;; minimax.el ends here
