;;; kargu/providers/nvidia.el --- Nvidia provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Nvidia (nvidia).

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
 :id "nvidia"
 :name "Nvidia"
 :api "https://integrate.api.nvidia.com/v1"
 :env '("NVIDIA_API_KEY")
 :models '("baai/bge-m3" "moonshotai/kimi-k2-instruct-0905" "moonshotai/kimi-k2.6" "minimaxai/minimax-m3" "minimaxai/minimax-m2.7" "stepfun-ai/step-3.7-flash" "stepfun-ai/step-3.5-flash" "google/gemma-3n-e4b-it" "google/gemma-3n-e2b-it" "google/google-paligemma" "google/gemma-4-31b-it" "google/gemma-2-2b-it" "microsoft/phi-4-mini-instruct" "microsoft/phi-4-multimodal-instruct" "z-ai/glm-5.2")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nvidia)

;;; nvidia.el ends here
