;;; kargu/providers/kimi-for-coding.el --- Kimi For Coding provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Kimi For Coding (kimi-for-coding).

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
 :id "kimi-for-coding"
 :name "Kimi For Coding"
 :api "https://api.kimi.com/coding/v1"
 :env '("KIMI_API_KEY")
 :models '("k2p7" "kimi-k2-thinking" "k2p5" "k2p6")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/kimi-for-coding)

;;; kimi-for-coding.el ends here
