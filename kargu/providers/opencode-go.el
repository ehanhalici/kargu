;;; kargu/providers/opencode-go.el --- OpenCode Go provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenCode Go (opencode-go).

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
 :id "opencode-go"
 :name "OpenCode Go"
 :api "https://opencode.ai/zen/go/v1"
 :models-api "https://opencode.ai/zen/go/v1/models"
 :env '("OPENCODE_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/opencode-go)

;;; opencode-go.el ends here
