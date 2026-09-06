;;; kargu/providers/bailing.el --- Bailing provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Bailing (bailing).

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
 :id "bailing"
 :name "Bailing"
 :api "https://api.tbox.cn/api/llm/v1/chat/completions"
 :env '("BAILING_API_TOKEN")
 :models '("Ring-1T" "Ling-1T")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/bailing)

;;; bailing.el ends here
