;;; kargu/providers/inceptron.el --- Inceptron provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Inceptron (inceptron).

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
 :id "inceptron"
 :name "Inceptron"
 :api "https://api.inceptron.io/v1"
 :env '("INCEPTRON_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.7-Code" "moonshotai/Kimi-K2.6-Fast" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5.2" "MiniMaxAI/MiniMax-M2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/inceptron)

;;; inceptron.el ends here
