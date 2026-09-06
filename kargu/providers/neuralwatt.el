;;; kargu/providers/neuralwatt.el --- Neuralwatt provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Neuralwatt (neuralwatt).

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
 :id "neuralwatt"
 :name "Neuralwatt"
 :api "https://api.neuralwatt.com/v1"
 :env '("NEURALWATT_API_KEY")
 :models '("kimi-k2.5-fast" "kimi-k2.6-flex" "glm-5.2-short-fast-flex" "glm-5.2-flex" "glm-5.2" "glm-5.2-short-fast" "qwen3.5-397b-fast" "kimi-k2.6-fast" "qwen3.6-35b-fast" "glm-5.2-short-flex" "glm-5.2-fast" "glm-5.2-short" "kimi-k2.7-code-flex" "moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/neuralwatt)

;;; neuralwatt.el ends here
