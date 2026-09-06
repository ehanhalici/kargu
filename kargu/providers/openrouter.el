;;; kargu/providers/openrouter.el --- OpenRouter provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OpenRouter (openrouter).

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
 :id "openrouter"
 :name "OpenRouter"
 :api "https://openrouter.ai/api/v1"
 :env '("OPENROUTER_API_KEY")
 :models '("inclusionai/ling-2.6-1t" "inclusionai/ring-2.6-1t" "inclusionai/ling-2.6-flash" "ibm-granite/granite-4.0-h-micro" "ibm-granite/granite-4.1-8b" "meta-llama/llama-3.1-8b-instruct" "meta-llama/llama-3.1-70b-instruct" "meta-llama/llama-3.2-1b-instruct" "meta-llama/llama-4-maverick" "meta-llama/llama-3.2-11b-vision-instruct" "meta-llama/llama-3.3-70b-instruct:free" "meta-llama/llama-3.3-70b-instruct" "meta-llama/llama-3.2-3b-instruct:free" "meta-llama/llama-guard-4-12b" "meta-llama/llama-4-scout")
 :npm "@openrouter/ai-sdk-provider")

(provide 'kargu/providers/openrouter)

;;; openrouter.el ends here
