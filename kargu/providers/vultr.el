;;; kargu/providers/vultr.el --- Vultr provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vultr (vultr).

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
 :id "vultr"
 :name "Vultr"
 :api "https://api.vultrinference.com/v1"
 :env '("VULTR_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "Qwen/Qwen3.6-27B" "Qwen/Qwen3.5-397B-A17B" "XiaomiMiMo/MiMo-V2.5-Pro" "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16" "nvidia/DeepSeek-V3.2-NVFP4" "nvidia/Nemotron-Cascade-2-30B-A3B" "zai-org/GLM-5.2-FP8" "deepseek-ai/DeepSeek-V4-Flash" "MiniMaxAI/MiniMax-M2.7")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/vultr)

;;; vultr.el ends here
