;;; kargu/providers/siliconflow.el --- SiliconFlow provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for SiliconFlow (siliconflow).

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
 :id "siliconflow"
 :name "SiliconFlow"
 :api "https://api.siliconflow.com/v1"
 :env '("SILICONFLOW_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "moonshotai/Kimi-K2.5" "baidu/ERNIE-4.5-300B-A47B" "ByteDance-Seed/Seed-OSS-36B-Instruct" "stepfun-ai/Step-3.5-Flash" "google/gemma-4-31B-it" "google/gemma-4-26B-A4B-it" "inclusionAI/Ling-flash-2.0" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen2.5-7B-Instruct" "Qwen/Qwen3-VL-235B-A22B-Instruct" "Qwen/Qwen3.6-27B" "Qwen/Qwen3.5-397B-A17B" "Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/siliconflow)

;;; siliconflow.el ends here
