;;; kargu/providers/iflowcn.el --- iFlow provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for iFlow (iflowcn).

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
 :id "iflowcn"
 :name "iFlow"
 :api "https://apis.iflow.cn/v1"
 :env '("IFLOW_API_KEY")
 :models '("qwen3-coder-plus" "deepseek-v3" "kimi-k2" "qwen3-32b" "qwen3-max-preview" "qwen3-max" "qwen3-235b" "glm-4.6" "qwen3-235b-a22b-thinking-2507" "deepseek-r1" "qwen3-vl-plus" "qwen3-235b-a22b-instruct" "kimi-k2-0905" "deepseek-v3.2")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/iflowcn)

;;; iflowcn.el ends here
