;;; kargu/providers/tinfoil.el --- Tinfoil provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Tinfoil (tinfoil).

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
 :id "tinfoil"
 :name "Tinfoil"
 :api "https://inference.tinfoil.sh/v1"
 :env '("TINFOIL_API_KEY")
 :models '("kimi-k2-6" "llama3-3-70b" "gpt-oss-safeguard-120b" "nomic-embed-text" "gpt-oss-120b" "glm-5-2" "gemma4-31b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/tinfoil)

;;; tinfoil.el ends here
