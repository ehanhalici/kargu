;;; kargu/providers/llmtr.el --- LLMTR provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for LLMTR (llmtr).

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
 :id "llmtr"
 :name "LLMTR"
 :api "https://llmtr.com/v1"
 :env '("LLMTR_API_KEY")
 :models '("sincap" "magibu-11b-v8" "gemma-4" "medgemma-4b" "qwen3-6-35b" "trendyol-7b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/llmtr)

;;; llmtr.el ends here
