;;; kargu/providers/siliconflow-cn.el --- SiliconFlow (China) provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for SiliconFlow (China) (siliconflow-cn).

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
 :id "siliconflow-cn"
 :name "SiliconFlow (China)"
 :api "https://api.siliconflow.cn/v1"
 :env '("SILICONFLOW_CN_API_KEY")
 :models '("baidu/ERNIE-4.5-300B-A47B" "ByteDance-Seed/Seed-OSS-36B-Instruct" "stepfun-ai/Step-3.5-Flash" "inclusionAI/Ling-flash-2.0" "Pro/moonshotai/Kimi-K2.6" "Pro/moonshotai/Kimi-K2.5" "Pro/zai-org/GLM-5" "Pro/zai-org/GLM-5.1" "Pro/deepseek-ai/DeepSeek-R1" "Pro/deepseek-ai/DeepSeek-V3.1-Terminus" "Pro/deepseek-ai/DeepSeek-V3.2" "Pro/deepseek-ai/DeepSeek-V3" "Pro/MiniMaxAI/MiniMax-M2.5" "Qwen/Qwen3.6-35B-A3B" "Qwen/Qwen3.5-397B-A17B")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/siliconflow-cn)

;;; siliconflow-cn.el ends here
