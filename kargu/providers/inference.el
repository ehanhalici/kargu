;;; kargu/providers/inference.el --- Inference provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Inference (inference).

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
 :id "inference"
 :name "Inference"
 :api "https://inference.net/v1"
 :env '("INFERENCE_API_KEY")
 :models '("mistral/mistral-nemo-12b-instruct" "google/gemma-3" "osmosis/osmosis-structure-0.6b" "qwen/qwen3-embedding-4b" "qwen/qwen-2.5-7b-vision-instruct" "meta/llama-3.1-8b-instruct" "meta/llama-3.2-1b-instruct" "meta/llama-3.2-11b-vision-instruct" "meta/llama-3.2-3b-instruct")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/inference)

;;; inference.el ends here
