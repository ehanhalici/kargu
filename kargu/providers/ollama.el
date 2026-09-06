;;; kargu/providers/ollama.el --- Ollama provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Ollama (ollama).

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
 :id "ollama"
 :name "Ollama"
 :api "http://localhost:11434/v1"
 :env nil
 :models '("qwen2.5-coder:latest" "deepseek-r1:latest" "llama3.2:latest")
 :npm "ollama")

(provide 'kargu/providers/ollama)

;;; ollama.el ends here
