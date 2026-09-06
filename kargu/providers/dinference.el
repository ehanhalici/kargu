;;; kargu/providers/dinference.el --- DInference provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for DInference (dinference).

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
 :id "dinference"
 :name "DInference"
 :api "https://api.dinference.com/v1"
 :env '("DINFERENCE_API_KEY")
 :models '("minimax-m2.5" "glm-4.7" "glm-5.1" "gpt-oss-120b" "glm-5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/dinference)

;;; dinference.el ends here
