;;; kargu/providers/inferx.el --- InferX provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for InferX (inferx).

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
 :id "inferx"
 :name "InferX"
 :api "https://model.inferx.net/v1"
 :env '("INFERX_API_KEY")
 :models '("google/gemma-4-31b-it-fp8" "qwen/qwen3-coder-next-fp8-1m" "qwen/qwen3.5-122b-a10b-nvfp4" "qwen/qwen3.6-35b-a3b-fp8" "qwen/qwen3-coder-next-fp8" "qwen/qwen3.6-27b-fp8")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/inferx)

;;; inferx.el ends here
