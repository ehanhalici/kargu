;;; kargu/providers/mixlayer.el --- Mixlayer provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Mixlayer (mixlayer).

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
 :id "mixlayer"
 :name "Mixlayer"
 :api "https://models.mixlayer.ai/v1"
 :env '("MIXLAYER_API_KEY")
 :models '("qwen/qwen3.5-27b" "qwen/qwen3.5-35b-a3b" "qwen/qwen3.5-9b" "qwen/qwen3.5-397b-a17b" "qwen/qwen3.5-122b-a10b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/mixlayer)

;;; mixlayer.el ends here
