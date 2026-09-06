;;; kargu/providers/zenmux.el --- ZenMux provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for ZenMux (zenmux).

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
 :id "zenmux"
 :name "ZenMux"
 :api "https://zenmux.ai/api/v1"
 :env '("ZENMUX_API_KEY")
 :models '("inclusionai/ling-1t" "inclusionai/ring-2.6-1t" "inclusionai/ring-1t" "moonshotai/kimi-k2.7-code-free" "moonshotai/kimi-k2-thinking-turbo" "moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2-thinking" "moonshotai/kimi-k2.5" "moonshotai/kimi-k2.6" "moonshotai/kimi-k2-0905" "baidu/ernie-5.0-thinking-preview" "google/gemini-3.1-flash-lite" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/zenmux)

;;; zenmux.el ends here
