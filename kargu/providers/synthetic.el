;;; kargu/providers/synthetic.el --- Synthetic provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Synthetic (synthetic).

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
 :id "synthetic"
 :name "Synthetic"
 :api "https://api.synthetic.new/openai/v1"
 :env '("SYNTHETIC_API_KEY")
 :models '("hf:moonshotai/Kimi-K2.7-Code" "hf:zai-org/GLM-4.7-Flash" "hf:zai-org/GLM-5.2" "hf:MiniMaxAI/MiniMax-M3" "hf:openai/gpt-oss-120b" "hf:Qwen/Qwen3.6-27B" "hf:nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/synthetic)

;;; synthetic.el ends here
