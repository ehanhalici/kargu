;;; kargu/providers/hpc-ai.el --- HPC-AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for HPC-AI (hpc-ai).

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
 :id "hpc-ai"
 :name "HPC-AI"
 :api "https://api.hpc-ai.com/inference/v1"
 :env '("HPC_AI_API_KEY")
 :models '("moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2.5" "openai/gpt-5.5" "anthropic/claude-opus-4.7" "zai-org/glm-5.1" "zai-org/glm-5.2" "deepseek/deepseek-v4-flash" "deepseek/deepseek-v4-pro" "minimax/minimax-m2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/hpc-ai)

;;; hpc-ai.el ends here
