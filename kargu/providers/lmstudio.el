;;; kargu/providers/lmstudio.el --- LMStudio provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for LMStudio (lmstudio).

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
 :id "lmstudio"
 :name "LMStudio"
 :api "http://127.0.0.1:1234/v1"
 :env '("LMSTUDIO_API_KEY")
 :models '("openai/gpt-oss-20b" "qwen/qwen3-30b-a3b-2507" "qwen/qwen3-coder-30b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/lmstudio)

;;; lmstudio.el ends here
