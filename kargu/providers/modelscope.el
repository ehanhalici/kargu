;;; kargu/providers/modelscope.el --- ModelScope provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for ModelScope (modelscope).

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
 :id "modelscope"
 :name "ModelScope"
 :api "https://api-inference.modelscope.cn/v1"
 :env '("MODELSCOPE_API_KEY")
 :models '("Qwen/Qwen3-30B-A3B-Thinking-2507" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-30B-A3B-Instruct" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-235B-A22B-Instruct-2507" "ZhipuAI/GLM-4.6" "ZhipuAI/GLM-4.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/modelscope)

;;; modelscope.el ends here
