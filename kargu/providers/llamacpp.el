;;; kargu/providers/llamacpp.el --- llama.cpp provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for llama.cpp (llamacpp).

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
 :id "llamacpp"
 :name "llama.cpp"
 :api "http://127.0.0.1:8080/v1"
 :env nil
 :models nil
 :npm "llamacpp")

(provide 'kargu/providers/llamacpp)

;;; llamacpp.el ends here
