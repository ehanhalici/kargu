;;; kargu/providers/freemodel.el --- FreeModel provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for FreeModel (freemodel).

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
 :id "freemodel"
 :name "FreeModel"
 :api "https://cc.freemodel.dev/v1"
 :env '("FREEMODEL_API_KEY")
 :models '("claude-haiku-4-5-20251001" "claude-opus-4-7" "claude-opus-4-8" "gpt-5.3-codex" "claude-fable-5" "gpt-5.4" "gpt-5.4-mini" "claude-opus-4-6" "claude-sonnet-4-6" "gpt-5.5")
 :npm "@ai-sdk/anthropic")

(provide 'kargu/providers/freemodel)

;;; freemodel.el ends here
