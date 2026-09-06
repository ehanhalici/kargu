;;; kargu/providers/qihang-ai.el --- QiHang provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for QiHang (qihang-ai).

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
 :id "qihang-ai"
 :name "QiHang"
 :api "https://api.qhaigc.net/v1"
 :env '("QIHANG_API_KEY")
 :models '("claude-haiku-4-5-20251001" "gemini-2.5-flash" "claude-opus-4-5-20251101" "gpt-5.2" "claude-sonnet-4-5-20250929" "gemini-3-pro-preview" "gpt-5-mini" "gemini-3-flash-preview" "gpt-5.2-codex")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/qihang-ai)

;;; qihang-ai.el ends here
