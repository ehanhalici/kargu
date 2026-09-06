;;; kargu/providers/meganova.el --- Meganova provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Meganova (meganova).

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
 :id "meganova"
 :name "Meganova"
 :api "https://api.meganova.ai/v1"
 :env '("MEGANOVA_API_KEY")
 :models '("meta-llama/Llama-3.3-70B-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2.5" "Qwen/Qwen2.5-VL-32B-Instruct" "Qwen/Qwen3.5-Plus" "Qwen/Qwen3-235B-A22B-Instruct-2507" "XiaomiMiMo/MiMo-V2-Flash" "mistralai/Mistral-Small-3.2-24B-Instruct-2506" "mistralai/Mistral-Nemo-Instruct-2407" "zai-org/GLM-4.6" "zai-org/GLM-5" "zai-org/GLM-4.7" "deepseek-ai/DeepSeek-V3-0324" "deepseek-ai/DeepSeek-R1-0528" "deepseek-ai/DeepSeek-V3.1")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/meganova)

;;; meganova.el ends here
