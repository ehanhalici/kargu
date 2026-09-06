;;; kargu/providers/alibaba.el --- Alibaba provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Alibaba (alibaba).

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
 :id "alibaba"
 :name "Alibaba"
 :api "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
 :env '("DASHSCOPE_API_KEY")
 :models '("qwen3-omni-flash" "qwen3-coder-plus" "qwen-plus" "qwen3-coder-30b-a3b-instruct" "qwen3-omni-flash-realtime" "qwen3-32b" "qwen-omni-turbo-realtime" "qwen-plus-character-ja" "qwen3-next-80b-a3b-instruct" "qwen3.7-plus" "qwen3.6-35b-a3b" "qwen3.7-max" "qwen3-max" "qwen2-5-omni-7b" "qwen3-8b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba)

;;; alibaba.el ends here
