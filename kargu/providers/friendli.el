;;; kargu/providers/friendli.el --- Friendli provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Friendli (friendli).

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
 :id "friendli"
 :name "Friendli"
 :api "https://api.friendli.ai/serverless/v1"
 :env '("FRIENDLI_TOKEN")
 :models '("google/gemma-4-31B-it" "Qwen/Qwen3-235B-A22B-Instruct-2507" "zai-org/GLM-5.2" "zai-org/GLM-5.1" "deepseek-ai/DeepSeek-V3.2" "MiniMaxAI/MiniMax-M2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/friendli)

;;; friendli.el ends here
