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
 :models-api "https://dashscope.aliyuncs.com/compatible-mode/v1/models"
 :env '("DASHSCOPE_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/alibaba-cn)

;;; alibaba-cn.el ends here
