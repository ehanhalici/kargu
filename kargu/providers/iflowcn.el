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
 :models-api "https://apis.iflow.cn/v1/models"
 :env '("IFLOW_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/iflowcn)

;;; iflowcn.el ends here
