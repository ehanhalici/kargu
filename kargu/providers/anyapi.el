;;; kargu/providers/anyapi.el --- AnyAPI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for AnyAPI (anyapi).

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
 :id "anyapi"
 :name "AnyAPI"
 :api "https://api.anyapi.ai/v1"
 :env '("ANYAPI_API_KEY")
 :models '("xai/grok-4.3" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-2.5-flash-lite" "google/gemini-3-pro-preview" "google/gemini-3-flash-preview" "openai/o3" "openai/gpt-5" "openai/o4-mini" "openai/o3-mini" "openai/gpt-5.2" "openai/gpt-5.4" "openai/gpt-4.1" "openai/gpt-5-mini" "openai/gpt-4.1-mini")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/anyapi)

;;; anyapi.el ends here
