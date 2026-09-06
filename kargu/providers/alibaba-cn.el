;;; kargu/providers/alibaba-cn.el --- Alibaba (China) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Alibaba (China) (alibaba-cn).

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
 :id "alibaba-cn"
 :name "Alibaba (China)"
 :api "https://dashscope.aliyuncs.com/compatible-mode/v1"
 :env '("DASHSCOPE_API_KEY")
 :models '("qwen2-5-math-72b-instruct" "deepseek-r1-0528" "qwen3-omni-flash" "deepseek-v4-flash" "qwen-plus" "qwen3-coder-30b-a3b-instruct" "qwen2-5-coder-7b-instruct" "deepseek-v3" "qwen3-omni-flash-realtime" "deepseek-r1-distill-llama-70b" "qwen3-32b" "qwen-omni-turbo-realtime" "qwen2-5-math-7b-instruct" "qwen3-next-80b-a3b-instruct" "qwen3.7-plus")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-cn)

;;; alibaba-cn.el ends here
