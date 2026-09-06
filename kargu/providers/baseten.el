;;; kargu/providers/baseten.el --- Baseten provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Baseten (baseten).

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
 :id "baseten"
 :name "Baseten"
 :api "https://inference.baseten.co/v1"
 :env '("BASETEN_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "moonshotai/Kimi-K2.7-Code" "openai/gpt-oss-120b" "nvidia/Nemotron-120B-A12B" "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B" "zai-org/GLM-5" "zai-org/GLM-4.7" "zai-org/GLM-5.2" "zai-org/GLM-5.1" "deepseek-ai/DeepSeek-V3.1" "deepseek-ai/DeepSeek-V4-Pro" "MiniMaxAI/MiniMax-M2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/baseten)

;;; baseten.el ends here
